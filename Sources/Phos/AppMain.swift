import SwiftUI
import CoreImage
import UniformTypeIdentifiers
import ImageIO
import Vision

struct PhotoItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var rating: Int = 0
    var picked: Bool = false
    var colorLabel: ColorLabel = .none
    var rejected: Bool = false
    var virtualCopyID: UUID? = nil
    var virtualCopyName: String? = nil
    var keywords: [String] = []
    var cameraModel: String = ""
    var lensModel: String = ""
    var thumb: CGImage?
    var isVirtualCopy: Bool { virtualCopyID != nil }
    var displayName: String {
        if let virtualCopyName, !virtualCopyName.isEmpty {
            return "\(url.deletingPathExtension().lastPathComponent) [\(virtualCopyName)]"
        }
        return url.deletingPathExtension().lastPathComponent
    }
    init(id: UUID = UUID(), url: URL, rating: Int = 0, picked: Bool = false,
         colorLabel: ColorLabel = .none, rejected: Bool = false,
         virtualCopyID: UUID? = nil, virtualCopyName: String? = nil,
         keywords: [String] = [], cameraModel: String = "", lensModel: String = "",
         thumb: CGImage? = nil) {
        self.id = id; self.url = url; self.rating = rating; self.picked = picked
        self.colorLabel = colorLabel; self.rejected = rejected
        self.virtualCopyID = virtualCopyID; self.virtualCopyName = virtualCopyName
        self.keywords = keywords; self.cameraModel = cameraModel; self.lensModel = lensModel
        self.thumb = thumb
    }
}

enum CanvasDisplayMode: String, CaseIterable {
    case single, grid, compare, reference
    var label: String {
        switch self {
        case .single: return "单张"
        case .grid: return "网格"
        case .compare: return "双图对比"
        case .reference: return "参考视图"
        }
    }
}

enum CompareSubMode: String, CaseIterable {
    case sideBySide, survey, beforeAfter
    var label: String {
        switch self {
        case .sideBySide: return "双图选片"
        case .survey: return "多图同屏"
        case .beforeAfter: return "修改前后"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    // 浏览器
    @Published var folder: URL?
    @Published var items: [PhotoItem] = []
    @Published var currentIndex: Int = 0
    @Published var filterRating: Int = 0
    @Published var filterPicked = false
    @Published var filterColorLabel: ColorLabel? = nil
    @Published var hideRejected = false
    @Published var filterCamera: String? = nil
    @Published var filterLens: String? = nil
    @Published var includeSubfolders = false {
        didSet {
            if oldValue != includeSubfolders, let folder {
                openFolder(folder)
            }
        }
    }
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
    @Published var currentKeywords: [String] = []
    private var currentVirtualCopies: [VirtualCopy] = []
    private var lastDecodedRawLensCorrection: Bool?
    var availableCameras: [String] {
        Array(Set(items.map(\.cameraModel).filter { !$0.isEmpty })).sorted()
    }
    var availableLenses: [String] {
        Array(Set(items.map(\.lensModel).filter { !$0.isEmpty })).sorted()
    }
    var visiblePhotoIndices: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var filtered = items.indices.filter {
            let it = items[$0]
            let cm = cullMetrics[it.id]
            let cullOK: Bool
            switch cullingFilter {
            case .all:
                cullOK = true
            case .bestShots:
                cullOK = cm != nil && !cm!.eyesClosed && !cm!.isBlurry && (cm!.overallScore >= 60 || cm!.isBurstBest)
            case .eyesClosed:
                cullOK = cm?.eyesClosed == true
            case .blurry:
                cullOK = cm?.isBlurry == true
            case .bursts:
                cullOK = cm?.isBurstBest == true
            }
            return cullOK &&
                   (filterRating == 0 || it.rating >= filterRating) &&
                   (!filterPicked || it.picked) &&
                   (filterColorLabel == nil || it.colorLabel == filterColorLabel) &&
                   (!hideRejected || !it.rejected) &&
                   (filterCamera == nil || it.cameraModel == filterCamera) &&
                   (filterLens == nil || it.lensModel == filterLens) &&
                   (query.isEmpty ||
                    (it.virtualCopyName?.localizedStandardContains(query) ?? false) ||
                    SemanticSearchEngine.matches(metrics: cm, fileName: it.url.lastPathComponent,
                                                 keywords: it.keywords, camera: it.cameraModel,
                                                 lens: it.lensModel, query: query))
        }
        if similarPhotoTargetID != nil, !similarPhotoOrder.isEmpty {
            let rank = Dictionary(uniqueKeysWithValues: similarPhotoOrder.enumerated().map { ($1, $0) })
            filtered.sort { (rank[items[$0].id] ?? Int.max) < (rank[items[$1].id] ?? Int.max) }
        }
        return filtered
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
    @Published var pointColorPicker = false {
        didSet {
            if pointColorPicker {
                whiteBalancePicker = false; retouchActive = false; bokehFocusPicker = false
                showBefore = false; splitComparison = false; cancelMaskDrawing()
            } else {
                localPointColorMaskID = nil
            }
        }
    }
    @Published var localPointColorMaskID: UUID? = nil
    @Published var edrEnabled = true
    @Published var showClippingWarning = false
    @Published var canvasDisplayMode: CanvasDisplayMode = .single
    @Published var compareSubMode: CompareSubMode = .sideBySide
    @Published var comparePrimaryID: UUID? = nil
    @Published var multiViewFrames: [UUID: PreviewFrame] = [:]
    private var multiViewLoadingIDs: Set<UUID> = []
    private var multiViewOrder: [UUID] = []
    @Published var referencePhotoURL: URL? = nil
    @Published var referenceFrame: PreviewFrame? = nil
    @Published var retouchActive = false {
        didSet {
            if retouchActive {
                whiteBalancePicker = false; pointColorPicker = false; bokehFocusPicker = false
                showBefore = false; splitComparison = false; cancelMaskDrawing()
                selectedMask = nil
            }
        }
    }
    @Published var showRetouchOverlay = true
    @Published var retouchMode: RetouchMode = .heal
    @Published var retouchRadius: Double = 0.035
    @Published var retouchFeather: Double = 0.45
    @Published var retouchOpacity: Double = 1.0
    @Published var selectedRetouchSpotID: UUID? = nil
    @Published var showNativeAI = false
    @Published var nativeAITab: NativeAITab = .edit
    @Published var showDepthOverlay = false {
        didSet { if oldValue != showDepthOverlay { previewQueue.invalidate(); render() } }
    }
    @Published var bokehFocusPicker = false {
        didSet {
            if bokehFocusPicker {
                whiteBalancePicker = false; pointColorPicker = false; retouchActive = false
                showBefore = false; splitComparison = false; cancelMaskDrawing()
            }
        }
    }
    @Published var cullMetrics: [UUID: PhotoCullMetrics] = [:]
    @Published var cullingRunning = false
    @Published var cullingProgress: Double = 0
    @Published var cullingFilter: CullingFilter = .all
    @Published var similarPhotoTargetID: UUID? = nil
    @Published var similarPhotoOrder: [UUID] = []
    private var cullFeatureCache: [UUID: VNFeaturePrintObservation] = [:]
    private var cullingTask: Task<Void, Never>? = nil
    @Published var autoSyncXMP: Bool = UserDefaults.standard.bool(forKey: "phos.autoSyncXMP") {
        didSet { UserDefaults.standard.set(autoSyncXMP, forKey: "phos.autoSyncXMP") }
    }
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
    @Published var brushAutoMask: Bool = false
    @Published var selectedMaskComponentID: UUID? = nil
    var maskPreviewImage: CGImage? { previewFrame?.mask }
    // A gradient is a transient draft until mouse-up: no sidecar writes or undo steps while drawing.
    @Published var maskDrawingKind: MaskKind?
    @Published var maskDrawingTarget: UUID?
    @Published var maskDraft: Mask?
    private var sidecarReadFailed = false

    weak var workspaceSession: WorkspaceSessionState?
    struct CropEditSession {
        let id = UUID()
        let photoID: UUID?
        let initial: EditParams
        let viewport: CanvasViewport?
        let pixel100: Bool
    }
    @Published private(set) var autoLevelRunning = false
    private(set) var cropSession: CropEditSession?
    @Published var splitComparison = false {
        didSet { if splitComparison { lensCompare = false; showBefore = false; cancelMaskDrawing(); render() } }
    }
    @Published private(set) var geometryBeforeFrame: PreviewFrame?
    @Published var lensGrid = false
    @Published var lensCompare = false {
        didSet { if oldValue != lensCompare { if lensCompare { showBefore = false; splitComparison = false }; render() } }
    }
    @Published var splitPosition: CGFloat = 0.5
    @Published var temporaryPan = false
    // 编辑
    @Published var params = EditParams()
    @Published var source: CIImage?
    @Published private(set) var previewFrame: PreviewFrame?
    @Published private(set) var beforeFrame: PreviewFrame?
    var preview: CGImage? { previewFrame?.image }
    @Published var previewing: Bool = false
    @Published var showBefore: Bool = false {
        didSet { if showBefore { lensCompare = false; splitComparison = false; cancelMaskDrawing(); refreshBefore() } }
    }
    var beforeImage: CGImage? { beforeFrame?.image }
    var displayFrame: PreviewFrame? { showBefore ? beforeFrame : previewFrame }
    var hist: PreviewFrame.Histogram { displayFrame?.histogram ?? ([], [], [], []) }
    @Published var status: String = "准备就绪"
    @Published var selectedMask: UUID? {
        willSet { if newValue != selectedMask { parameterEdits.finishCurrent() } }
        didSet {
            if oldValue != selectedMask {
                selectedMaskComponentID = nil
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
    @Published var syncProgress: Double = 0
    @Published var jobFailures: [String] = []
    var jobCancellation: WorkspaceCancellation?
    var batchTask: Task<Void,Never>?

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
        guard let self else { return }
        for idx in items.indices where items[idx].url == url {
            if let image { items[idx].thumb = image; thumbnailFailures.remove(items[idx].id) }
            else { thumbnailFailures.insert(items[idx].id) }
        }
    }
    var thumbnailCacheCount: Int { thumbnails.cachedCount }
    var thumbnailActiveCount: Int { thumbnails.activeCount }
    private var previewRevision: UInt64 = 0
    private var expectedPreview: PreviewFrameKey?
    private var expectedBefore: PreviewFrameKey?
    private struct CachedSource {
        let image: CIImage
        let rawLensCorrection: Bool
    }
    private let sourceCache = BoundedCache<URL, CachedSource>(capacity: 5)
    private var prefetchTask: Task<Void, Never>?
    private let previewLongEdge: CGFloat = 2200
    private struct FolderScanRequest {
        let url: URL
        let recursive: Bool
    }
    private struct PhotoLoad {
        let url: URL
        let cached: CIImage?
        let rawEmbeddedLensCorrection: Bool
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
        let split: Bool
        var showDepthOverlay: Bool = false
    }
    nonisolated private static func lightweightCameraLens(_ url: URL) -> (camera: String, lens: String) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let meta = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return ("", "") }
        let exif = meta[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = meta[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let cam = (tiff[kCGImagePropertyTIFFModel as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lens = (exif[kCGImagePropertyExifLensModel as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cam, lens)
    }
    private lazy var folderQueue = LatestWorkQueue<FolderScanRequest, [PhotoItem]?>(
        priority: .userInitiated,
        operation: { req in
            let url = req.url
            var collected: [URL] = []
            if req.recursive {
                guard let en = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { return nil }
                for case let fileURL as URL in en {
                    if Engine.browseSet.contains(fileURL.pathExtension.lowercased()) {
                        collected.append(fileURL)
                    }
                }
            } else {
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil) else { return nil }
                collected = files.filter { Engine.browseSet.contains($0.pathExtension.lowercased()) }
            }
            let sortedURLs = collected.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            var list: [PhotoItem] = []
            for url in sortedURLs {
                autoreleasepool {
                    let sidecar = SidecarStore.load(for: url) ?? XMPSidecar.read(for: url)?.toSidecar()
                    let meta = Self.lightweightCameraLens(url)
                    let kws = sidecar?.keywords ?? []
                    var item = PhotoItem(url: url, keywords: kws, cameraModel: meta.camera, lensModel: meta.lens)
                    if let sidecar {
                        item.rating = sidecar.rating
                        item.picked = sidecar.picked
                        item.colorLabel = sidecar.colorLabel
                        item.rejected = sidecar.rejected
                    }
                    list.append(item)
                    if let copies = sidecar?.virtualCopies {
                        for vc in copies {
                            list.append(PhotoItem(id: vc.id, url: url, rating: vc.rating, picked: vc.picked,
                                                  colorLabel: vc.colorLabel, rejected: vc.rejected,
                                                  virtualCopyID: vc.id, virtualCopyName: vc.name,
                                                  keywords: kws, cameraModel: meta.camera, lensModel: meta.lens))
                        }
                    }
                }
            }
            return list
        },
        completion: { [weak self] req, result in
            guard let self, self.folder == req.url else { return }
            self.folderLoading = false
            guard let result else { self.status = "无法读取文件夹"; self.folderFailure = self.status; return }
            self.items = result
            var hydrated: [UUID: PhotoCullMetrics] = [:]
            for it in result {
                if let cached = SmartCullingEngine.cachedMetrics(for: it.url) {
                    hydrated[it.id] = cached
                }
            }
            self.cullMetrics = hydrated
            self.status = result.isEmpty ? "文件夹里没有支持的图像" : "共 \(result.count) 张"
            if !result.isEmpty { self.select(0) }
            self.loadThumbnails()
        })
    private lazy var sourceQueue = LatestWorkQueue<PhotoLoad, (CIImage?, Bool)>(
        operation: { [workMetrics] request in
            if request.cached == nil { workMetrics.increment("decode") }
            return (request.cached ?? Engine.decode(request.url, rawEmbeddedLensCorrection: request.rawEmbeddedLensCorrection),
                    Engine.hasDisparity(request.url))
        },
        completion: { [weak self] request, result in
            guard let self, self.current?.url == request.url else { return }
            self.source = result.0
            self.sourceSize = result.0?.extent.size ?? .zero
            self.hasDisparity = result.1
            self.lastDecodedRawLensCorrection = request.rawEmbeddedLensCorrection
            if let img = result.0 {
                self.sourceCache[request.url] = CachedSource(image: img, rawLensCorrection: request.rawEmbeddedLensCorrection)
            } else {
                self.sourceCache[request.url] = nil
            }
            if result.0 == nil {
                self.previewing = false
                self.status = "无法解码 \(request.url.lastPathComponent)"
                return
            }
            self.render()
            if self.showBefore { self.refreshBefore() }
            self.prefetchNeighborSources()
        })
    private lazy var previewQueue: LatestWorkQueue<PreviewRequest, (edited:PreviewFrame,before:PreviewFrame?)?> = LatestWorkQueue(
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
            if let result {
                previewFrame = result.edited; geometryBeforeFrame = result.before
                #if PHOS_QA
                WorkspaceReviewBench.recordFirstPreview()
                #endif
            }
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
        if cropSession != nil { cancelCrop() }
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
        prefetchTask?.cancel()
        folderQueue.invalidate()
        sourceQueue.invalidate()
        previewQueue.invalidate()
        beforeQueue.invalidate()
        thumbnails.reset()
        currentIndex = -1
        source = nil
        previewFrame = nil
        beforeFrame = nil
        referencePhotoURL = nil
        referenceFrame = nil
        expectedPreview = nil; expectedBefore = nil
        sourceSize = .zero
        hasDisparity = false
        previewing = false
        items = []
        selectedPhotos = []
        snapshots = []
        selectedMask = nil
        selectedMaskComponentID = nil
        localPointColorMaskID = nil
        whiteBalancePicker = false
        pointColorPicker = false
        bokehFocusPicker = false
        showDepthOverlay = false
        cullingTask?.cancel()
        cullingTask = nil
        cullingRunning = false
        cullingProgress = 0
        cullingFilter = .all
        cullMetrics.removeAll()
        cullFeatureCache.removeAll()
        similarPhotoTargetID = nil
        similarPhotoOrder.removeAll()
        filterCamera = nil
        filterLens = nil
        comparePrimaryID = nil
        multiViewFrames.removeAll()
        multiViewOrder.removeAll()
        multiViewLoadingIDs.removeAll()
        clearAutoTone()
        sourceCache.removeAll()
        folder = url
        folderLoading = true; folderFailure = nil; thumbnailFailures = []; savedSidecarFingerprint = nil
        status = "正在读取文件夹…"
        folderQueue.submit(FolderScanRequest(url: url, recursive: includeSubfolders))
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
        if cropSession != nil { cancelCrop() }
        let finish = finishPendingPhotoEdit; finishPendingPhotoEdit = nil; pendingPhotoEditID = nil; finish?()
        guard saveCurrent() else { return false }
        workMetrics.increment("select")
        cancelMaskDrawing()
        prefetchTask?.cancel()
        sourceQueue.invalidate()
        previewQueue.invalidate()
        beforeQueue.invalidate()
        lensCompare = false; lensGrid = false
        currentIndex = i
        let u = items[i].url
        let vcID = items[i].virtualCopyID
        source = nil
        previewFrame = nil
        beforeFrame = nil
        expectedPreview = nil; expectedBefore = nil
        sourceSize = .zero
        previewing = true
        hasDisparity = false
        whiteBalancePicker = false
        pointColorPicker = false
        localPointColorMaskID = nil
        selectedMaskComponentID = nil
        selectedRetouchSpotID = nil
        clearAutoTone()
        sidecarReadFailed = false
        params = EditParams(); history.stack = []; history.index = -1
        currentKeywords = []; currentVirtualCopies = []
        do {
            let stored = try SidecarStore.read(for: u)
            let xmpFallback = stored == nil ? XMPSidecar.read(for: u)?.toSidecar() : nil
            let sc = stored ?? xmpFallback
            snapshots = sc?.snapshots ?? []
            currentKeywords = sc?.keywords ?? []
            currentVirtualCopies = sc?.virtualCopies ?? []
            if let vcID, let vc = sc?.virtualCopies.first(where: { $0.id == vcID }) {
                params = vc.params
                items[i].rating = vc.rating; items[i].picked = vc.picked
                items[i].colorLabel = vc.colorLabel; items[i].rejected = vc.rejected
            } else if let sc {
                params = sc.params
                items[i].rating = sc.rating; items[i].picked = sc.picked
                items[i].colorLabel = sc.colorLabel; items[i].rejected = sc.rejected
            }
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
        let rawLens = params.rawEmbeddedLensCorrection
        let cachedImg = sourceCache[u].flatMap { $0.rawLensCorrection == rawLens ? $0.image : nil }
        sourceQueue.submit(PhotoLoad(url: u, cached: cachedImg, rawEmbeddedLensCorrection: rawLens))
        return true
    }

    // MARK: - 参数改动
    func commit(_ p: EditParams) {
        guard !syncRunning else { return }
        parameterEdits.invalidate()
        let rawLensChanged = p.rawEmbeddedLensCorrection != lastDecodedRawLensCorrection
        params = p
        if let cid = current?.id { multiViewFrames.removeValue(forKey: cid) }
        if cropSession != nil { render(); return }
        history.push(p)
        if rawLensChanged, let u = current?.url {
            sourceCache[u] = nil
            sourceQueue.submit(PhotoLoad(url: u, cached: nil, rawEmbeddedLensCorrection: p.rawEmbeddedLensCorrection))
        } else {
            render()
        }
        autoSave()
    }

    func undo() {
        guard !syncRunning else { return }
        if cropSession != nil { cancelCrop(); return }
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

    private func buildSidecarForCurrent(existing: Sidecar?) -> Sidecar {
        let it = current!
        if let vcID = it.virtualCopyID {
            var base = existing ?? Sidecar(params: EditParams())
            var copies = base.virtualCopies
            if let idx = copies.firstIndex(where: { $0.id == vcID }) {
                copies[idx].params = params
                copies[idx].rating = it.rating
                copies[idx].picked = it.picked
                copies[idx].colorLabel = it.colorLabel
                copies[idx].rejected = it.rejected
            } else {
                copies.append(VirtualCopy(
                    id: vcID, name: it.virtualCopyName ?? "副本",
                    params: params, rating: it.rating, picked: it.picked,
                    colorLabel: it.colorLabel, rejected: it.rejected
                ))
            }
            base.virtualCopies = copies
            currentVirtualCopies = copies
            return base
        } else {
            return Sidecar(
                params: params, rating: it.rating, picked: it.picked, snapshots: snapshots,
                colorLabel: it.colorLabel, rejected: it.rejected,
                keywords: currentKeywords, virtualCopies: currentVirtualCopies
            )
        }
    }

    private func sidecarFingerprint() -> Data? {
        guard let it = current else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let vcID = it.virtualCopyID {
            let vc = VirtualCopy(
                id: vcID, name: it.virtualCopyName ?? "副本", created: Date(timeIntervalSince1970: 0),
                params: params, rating: it.rating, picked: it.picked,
                colorLabel: it.colorLabel, rejected: it.rejected
            )
            return try? encoder.encode(vc)
        }
        return try? encoder.encode(Sidecar(
            params: params, rating: it.rating, picked: it.picked, snapshots: snapshots,
            colorLabel: it.colorLabel, rejected: it.rejected,
            keywords: currentKeywords, virtualCopies: currentVirtualCopies
        ))
    }

    @discardableResult
    func saveCurrent() -> Bool {
        guard cropSession == nil else { return true }
        guard !sidecarReadFailed, let it = current else { return true }
        let fingerprint = sidecarFingerprint()
        if fingerprint != nil, fingerprint == savedSidecarFingerprint { return true }
        do {
            let existing = try SidecarStore.read(for: it.url)
            let sc = buildSidecarForCurrent(existing: existing)
            try SidecarStore.write(sc, for: it.url)
            if autoSyncXMP && !it.isVirtualCopy {
                try? XMPSidecar.write(sc, for: it.url)
            }
            workMetrics.increment("sidecarWrite"); savedSidecarFingerprint = fingerprint
            return true
        } catch {
            workflowError = "编辑记录保存失败：\(it.url.lastPathComponent)\n\(error.localizedDescription)"
            return false
        }
    }

    func setRating(_ r: Int) {
        guard let id = current?.id, !sidecarReadFailed, !syncRunning else { return }
        setRating(r, for: id)
    }
    func togglePick() {
        guard let id = current?.id, !sidecarReadFailed, !syncRunning else { return }
        togglePick(for: id)
    }
    func setColorLabel(_ label: ColorLabel) {
        guard let id = current?.id, !sidecarReadFailed, !syncRunning else { return }
        setColorLabel(label, for: id)
    }
    func toggleReject() {
        guard let id = current?.id, !sidecarReadFailed, !syncRunning else { return }
        toggleReject(for: id)
    }

    func setRating(_ r: Int, for itemID: UUID) {
        mutateItemMetadata(itemID: itemID) { it in it.rating = min(max(r, 0), 5) }
    }
    func togglePick(for itemID: UUID) {
        mutateItemMetadata(itemID: itemID) { it in
            it.picked.toggle()
            if it.picked { it.rejected = false }
        }
    }
    func setColorLabel(_ label: ColorLabel, for itemID: UUID) {
        mutateItemMetadata(itemID: itemID) { it in
            it.colorLabel = it.colorLabel == label ? .none : label
        }
    }
    func toggleReject(for itemID: UUID) {
        mutateItemMetadata(itemID: itemID) { it in
            it.rejected.toggle()
            if it.rejected { it.picked = false }
        }
    }

    private func mutateItemMetadata(itemID: UUID, _ body: (inout PhotoItem) -> Void) {
        guard !syncRunning, let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        if idx == currentIndex {
            guard !sidecarReadFailed else { return }
            body(&items[idx])
            saveCurrent()
            return
        }
        var updated = items[idx]
        body(&updated)
        items[idx] = updated
        do {
            let existing = try SidecarStore.read(for: updated.url)
            var base = existing ?? Sidecar(params: EditParams())
            if let vcID = updated.virtualCopyID,
               let vIdx = base.virtualCopies.firstIndex(where: { $0.id == vcID }) {
                base.virtualCopies[vIdx].rating = updated.rating
                base.virtualCopies[vIdx].picked = updated.picked
                base.virtualCopies[vIdx].colorLabel = updated.colorLabel
                base.virtualCopies[vIdx].rejected = updated.rejected
            } else if updated.virtualCopyID == nil {
                base.rating = updated.rating
                base.picked = updated.picked
                base.colorLabel = updated.colorLabel
                base.rejected = updated.rejected
            }
            try SidecarStore.write(base, for: updated.url)
            if autoSyncXMP && !updated.isVirtualCopy {
                try? XMPSidecar.write(base, for: updated.url)
            }
            workMetrics.increment("sidecarWrite")
        } catch {
            workflowError = "元数据保存失败：\(updated.url.lastPathComponent)\n\(error.localizedDescription)"
        }
    }

    // MARK: - 裁剪模式辅助
    func toggleCropMode() {
        guard source != nil, !syncRunning else { return }
        if cropSession != nil { finishCrop(); return }
        parameterEdits.finishCurrent()
        NSApp?.keyWindow?.makeFirstResponder(nil)
        cropSession = CropEditSession(photoID:current?.id, initial:params, viewport:workspaceSession?.viewport, pixel100:oneToOne)
        cancelMaskDrawing(); splitComparison = false; showBefore = false; whiteBalancePicker = false
        selectedMask = nil; oneToOne = false; cropMode = true
        previewQueue.invalidate(); render()
    }
    func finishCrop() {
        guard let edit = cropSession, edit.photoID == current?.id else { return }
        parameterEdits.finishCurrent()
        cropSession = nil; cropMode = false
        if params != edit.initial { history.push(params); saveCurrent() }
        render()
    }
    func cancelCrop() {
        guard let edit = cropSession else { return }
        parameterEdits.invalidate()
        cropSession = nil; params = edit.initial; cropMode = false
        if let viewport = edit.viewport { workspaceSession?.viewport = viewport }
        oneToOne = edit.pixel100
        previewQueue.invalidate(); render()
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
        guard let src = source, !autoLevelRunning else { return }
        parameterEdits.finishCurrent()
        let initial = params
        var analysis = params.cropNeutral; analysis.straighten = 0
        let photoID = current?.id, cropID = cropSession?.id
        autoLevelRunning = true
        status = "检测地平线…"
        Task {
            defer { autoLevelRunning = false }
            let analysisParams = analysis
            let detected = await Task.detached {
                let image = Engine.geometry(src, analysisParams)
                return (Engine.autoStraightenAngle(from: image), image.extent.size)
            }.value
            guard current?.id == photoID, cropSession?.id == cropID else { return }
            guard params == initial else { status = "已保留新的调整，请重新自动水平"; return }
            let angle = detected.0
            guard let a = angle else {
                await MainActor.run { status = "未检测到地平线" }
                return
            }
            guard a.isFinite, abs(a) <= 15 else { status = "倾斜超过 15°，请手动校正"; return }
            await MainActor.run {
                set(\.straighten, a)
                // 旋转后画幅外接框尺寸
                let rad = abs(a) * .pi / 180
                let cw = detected.1.width * CGFloat(cos(rad)) + detected.1.height * CGFloat(sin(rad))
                let chh = detected.1.width * CGFloat(sin(rad)) + detected.1.height * CGFloat(cos(rad))
                let ins = Engine.inscribedCrop(canvasW: cw, canvasH: chh, angleDeg: a)
                set(\.cropX, ins.x); set(\.cropY, ins.y)
                set(\.cropW, ins.w); set(\.cropH, ins.h)
                endEdit()
                status = String(format: "地平线校直 %.1f°，已按最大内接矩形裁切", a)
            }
        }
    }

    private var previewWorkSuspended = false
    func suspendPreviewWork() {
        previewWorkSuspended = true
        prefetchTask?.cancel()
        folderQueue.invalidate(); sourceQueue.invalidate(); previewQueue.invalidate(); beforeQueue.invalidate()
        thumbnails.reset(); folderLoading = false; previewing = false; temporaryPan = false
    }
    func resumePreviewWork() {
        guard previewWorkSuspended else { return }
        previewWorkSuspended = false
        if source != nil { render() }
        else if current != nil { _ = select(currentIndex) }
        else if let folder { openFolder(folder) }
    }

    // MARK: - 渲染
    func render() {
        guard let src = source else { return }
        previewing = true
        // Preview-only comparison never changes history, sidecars, or exported parameters.
        var previewParams = cropMode ? params.cropNeutral : params
        if lensCompare && !cropMode { previewParams.lensCorrection = nil }
        // 裁剪模式下预览未裁剪的整幅（裁剪框叠加层直接在画布上改），退出后恢复
        submitPreview(source: src, parameters: previewParams,
                      mask: showMaskOverlay && !cropMode ? selectedMask : nil)
    }

    private func submitPreview(source: CIImage, parameters: EditParams, mask: UUID?) {
        guard let photoID = current?.id else { return }
        previewRevision &+= 1
        let depthVis = showDepthOverlay && !cropMode
        let key = PreviewFrameKey(photoID: photoID, revision: previewRevision,
                                  purpose: cropMode ? .cropReference : .edited,
                                  paramsFingerprint: PreviewFrame.fingerprint(parameters) + (depthVis ? "|depthVis" : ""))
        expectedPreview = key
        previewQueue.submit(PreviewRequest(key: key, source: source, params: parameters,
                                           url: current?.url, fullResolution: fullResPreview || oneToOne,
                                           cropMode: cropMode, longEdge: previewLongEdge, overlayMask: mask,
                                           split: splitComparison, showDepthOverlay: depthVis))
    }
    nonisolated private static func makePreview(_ request: PreviewRequest) -> (edited:PreviewFrame,before:PreviewFrame?)? {
        let src = request.source, p = request.params, e = src.extent
        let scale: CGFloat = request.fullResolution ? 1 : min(1, request.longEdge / max(e.width, e.height))
        let base = scale < 1 ? src.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : src
        var disparity: CIImage?
        if !request.cropMode, (p.bokehAmount > 0 || request.showDepthOverlay),
           !p.masks.contains(where: { $0.kind == .depth && $0.enabled }), let url = request.url {
            disparity = Engine.disparityBokehMask(for: url, target: base.extent)
        }
        let resolved = Engine.resolvedPerspective(src,p)
        var mask: CIImage?
        var out = Engine.render(base, p, disparityMask: disparity, selectedMask: request.overlayMask, resolvedAuto:resolved) { mask = $0 }
        if request.showDepthOverlay && !request.cropMode {
            out = Engine.applyDepthVisualization(out, p, disparityMask: disparity)
        }
        guard let image = Engine.ctx.createCGImage(out, from: out.extent, format: .RGBA8,
                                                   colorSpace: Engine.srgb) else { return nil }
        // Histogram the displayed pixels without evaluating the RAW/filter graph a second time.
        let histogram = Engine.histogram(CIImage(cgImage: image))
        let maskCG = mask.flatMap { Engine.maskOverlayImage($0, extent: out.extent) }
        let edited = PreviewFrame(key: request.key, image: image, mask: maskCG, maskID: request.overlayMask,
                            histogram: histogram, renderExtent: out.extent,
                            editedExtent: out.extent.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)),
                            proxyScale: scale, fullResolution: request.fullResolution || scale == 1,
                            metalImage: out)
        var before: PreviewFrame?
        if request.split, !request.cropMode {
            var geometry = EditGroup.applying(p,to:EditParams(),groups:[.geometry])
            geometry.lensCorrection = p.lensCorrection // Split comparison keeps lens geometry aligned.
            let neutral = Engine.render(base,geometry,resolvedAuto:resolved)
            if let bitmap = Engine.ctx.createCGImage(neutral,from:out.extent,format:.RGBA8,colorSpace:Engine.srgb) {
                before = PreviewFrame(key:PreviewFrameKey(photoID:request.key.photoID,revision:request.key.revision,purpose:.beforeGeometry,paramsFingerprint:request.key.paramsFingerprint),image:bitmap,mask:nil,maskID:nil,histogram:([],[],[],[]),renderExtent:out.extent,editedExtent:edited.editedExtent,proxyScale:scale,fullResolution:edited.fullResolution)
            }
        }
        return (edited,before)
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
        NSApp?.keyWindow?.makeFirstResponder(nil)
        selectedMask = id
        if cropSession != nil { cancelCrop() }
        cropMode = false
        splitComparison = false
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

    func createMask(_ kind: MaskKind) {
        parameterEdits.finishCurrent()
        NSApp?.keyWindow?.makeFirstResponder(nil)
        if cropSession != nil { finishCrop() }
        showBefore = false; splitComparison = false; whiteBalancePicker = false
        inspectorUI.category = .masks; workspaceSession?.inspectorVisible = true
        if kind == .linear || kind == .radial { startMaskDrawing(kind) }
        else { addMask(kind); showMaskOverlay = true }
    }
    func activateBrush() {
        parameterEdits.finishCurrent()
        NSApp?.keyWindow?.makeFirstResponder(nil)
        if cropSession != nil { finishCrop() }
        showBefore = false; splitComparison = false; whiteBalancePicker = false
        inspectorUI.category = .masks; workspaceSession?.inspectorVisible = true
        if selectedMask == nil || !params.masks.contains(where: { $0.id == selectedMask }) { addMask(.brush) }
        maskTool = .paint; showMaskOverlay = true
        status = "在照片上拖动添加选区；一次拖动一笔，Esc 取消当前笔画"
    }
    func renameMask(_ id:UUID,name:String) {
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, var mask = params.masks.first(where:{$0.id == id}) else { return }
        mask.name = String(name.prefix(120)); updateMask(mask)
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

    func updateMaskComponent(maskID: UUID, component: MaskComponent) {
        var p = params
        guard let mIdx = p.masks.firstIndex(where: { $0.id == maskID }),
              let cIdx = p.masks[mIdx].components.firstIndex(where: { $0.id == component.id }) else { return }
        p.masks[mIdx].components[cIdx] = component
        MaskEngine.invalidateCache(for: component.id)
        commit(p)
    }

    func updateMaskComponentLive(maskID: UUID, component: MaskComponent) {
        var p = params
        guard let mIdx = p.masks.firstIndex(where: { $0.id == maskID }),
              let cIdx = p.masks[mIdx].components.firstIndex(where: { $0.id == component.id }) else { return }
        p.masks[mIdx].components[cIdx] = component
        MaskEngine.invalidateCache(for: component.id)
        params = p
        render()
    }

    func recomputeMaskComponent(maskID: UUID, componentID: UUID) {
        MaskEngine.invalidateCache(for: componentID)
        previewQueue.invalidate()
        render()
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
        guard let src = source, !jobRunning else { return }
        let sourceURL = current?.url
        let parameters = params, settings = exportSettings
        let cancellation = WorkspaceCancellation(); jobCancellation = cancellation; jobFailures = []
        exportRunning = true
        status = "正在导出 \(url.lastPathComponent)…"
        Task {
            let error: String? = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    var rendered = Engine.render(src, parameters, forExport: true)
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
                        if cancellation.cancelled { return "已取消" }
                        let staging = url.deletingLastPathComponent().appendingPathComponent(".phos-export-"+UUID().uuidString+"."+settings.format)
                        defer { try? FileManager.default.removeItem(at:staging) }
                        try Engine.write(rendered, to: staging, settings: settings, sourceURL: sourceURL)
                        if cancellation.cancelled { return "已取消" }
                        if FileManager.default.fileExists(atPath:url.path) { _ = try FileManager.default.replaceItemAt(url,withItemAt:staging) }
                        else { try FileManager.default.moveItem(at:staging,to:url) }
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
            }.value
            exportRunning = false; jobCancellation = nil
            if cancellation.cancelled { status = "导出已取消"; return }
            if let error { jobFailures = [error]; workflowError = "导出失败，可重试：\(error)" }
            status = error.map { "导出失败：\($0)" } ?? "已导出 \(url.lastPathComponent)"
        }
    }

    func batchExport(to dir: URL, onlyPicked: Bool) async {
        guard !jobRunning else { return }
        let list = items.filter { !onlyPicked || $0.picked }
        guard !list.isEmpty else {
            status = "没有符合条件的照片可导出"
            return
        }
        guard saveCurrent() else { return }
        let cancellation = WorkspaceCancellation(); jobCancellation = cancellation; jobFailures = []
        batchRunning = true
        defer { batchRunning = false; jobCancellation = nil; batchTask = nil }
        batchProgress = 0
        let settings = exportSettings
        let concurrency = 3
        var nextIndex = 0
        var completed = 0
        var failed = 0

        await withTaskGroup(of: (String, String?).self) { group in
            func enqueueNext() {
                guard nextIndex < list.count, !Task.isCancelled, !cancellation.cancelled else { return }
                let it = list[nextIndex]
                nextIndex += 1
                let suffix = it.virtualCopyName.map { "_\($0.replacingOccurrences(of: "/", with: "-"))" } ?? ""
                let dest = dir.appendingPathComponent(it.url.deletingPathExtension().lastPathComponent + suffix + ".\(settings.format)")
                let vcID = it.virtualCopyID
                let label = it.displayName
                group.addTask(priority: .userInitiated) {
                    let error = Self.exportBatchItem(it.url, virtualCopyID: vcID, to: dest, settings: settings, cancellation: cancellation)
                    return (label, error)
                }
            }
            for _ in 0..<min(concurrency, list.count) { enqueueNext() }
            for await (label, error) in group {
                completed += 1
                if let error, error != "已取消" {
                    failed += 1
                    jobFailures.append(label + "：" + error)
                }
                batchProgress = Double(completed) / Double(max(list.count, 1))
                status = "批量导出 \(completed)/\(list.count) 张"
                if cancellation.cancelled || Task.isCancelled { break }
                enqueueNext()
            }
        }
        if cancellation.cancelled || Task.isCancelled {
            status = "批量导出已取消，已处理 \(completed)/\(list.count) 张"
            return
        }
        if !jobFailures.isEmpty { workflowError = "以下照片导出失败，可重试：\n"+jobFailures.joined(separator:"\n") }
        status = failed == 0
            ? "批量导出完成：\(list.count) 张"
            : "批量导出完成：成功 \(list.count - failed) 张，失败 \(failed) 张"
    }

    nonisolated private static func exportBatchItem(_ url: URL, virtualCopyID: UUID? = nil, to dest: URL,
                                                 settings: ExportSettings, cancellation: WorkspaceCancellation) -> String? {
        autoreleasepool {
            guard !cancellation.cancelled else { return "已取消" }
            do {
                let sidecar = try SidecarStore.read(for: url)
                let params: EditParams
                if let vcID = virtualCopyID, let vc = sidecar?.virtualCopies.first(where: { $0.id == vcID }) {
                    params = vc.params
                } else {
                    params = sidecar?.params ?? XMPSidecar.read(for: url)?.params ?? EditParams()
                }
                guard let src = Engine.decode(url, rawEmbeddedLensCorrection: params.rawEmbeddedLensCorrection) else {
                    return "无法解码"
                }
                let rendered = Engine.render(src, params, forExport: true)
                if cancellation.cancelled { return "已取消" }
                let staging = dest.deletingLastPathComponent().appendingPathComponent(".phos-batch-"+UUID().uuidString+"."+settings.format)
                defer { try? FileManager.default.removeItem(at:staging) }
                try Engine.write(rendered, to: staging, settings: settings, sourceURL: url)
                if cancellation.cancelled { return "已取消" }
                if FileManager.default.fileExists(atPath:dest.path) { _ = try FileManager.default.replaceItemAt(dest,withItemAt:staging) }
                else { try FileManager.default.moveItem(at:staging,to:dest) }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    // MARK: - 邻张静默预解码 / 虚拟副本 / XMP / 参考图 / 点颜色 / 修复污点
    private func prefetchNeighborSources() {
        prefetchTask?.cancel()
        #if PHOS_TESTING
        return
        #else
        let rawLens = params.rawEmbeddedLensCorrection
        var neighbors: [URL] = []
        if let n = nextVisiblePhotoIndex, items.indices.contains(n) { neighbors.append(items[n].url) }
        if let p = previousVisiblePhotoIndex, items.indices.contains(p) { neighbors.append(items[p].url) }
        let unique = Array(Set(neighbors)).filter { u in
            if let hit = sourceCache[u], hit.rawLensCorrection == rawLens { return false }
            return true
        }
        guard !unique.isEmpty else { return }
        prefetchTask = Task.detached(priority: .utility) { [weak self] in
            for u in unique {
                if Task.isCancelled { return }
                if let ci = Engine.decode(u, rawEmbeddedLensCorrection: rawLens) {
                    await MainActor.run { [weak self] in
                        guard let self, !Task.isCancelled else { return }
                        self.sourceCache[u] = CachedSource(image: ci, rawLensCorrection: rawLens)
                    }
                }
            }
        }
        #endif
    }

    func createVirtualCopy() {
        guard let it = current, !sidecarReadFailed, !syncRunning else { return }
        parameterEdits.finishCurrent()
        _ = saveCurrent()
        do {
            var base = try SidecarStore.read(for: it.url) ?? Sidecar(
                params: it.isVirtualCopy ? EditParams() : params,
                rating: it.isVirtualCopy ? 0 : it.rating,
                picked: it.isVirtualCopy ? false : it.picked,
                snapshots: snapshots,
                colorLabel: it.isVirtualCopy ? .none : it.colorLabel,
                rejected: it.isVirtualCopy ? false : it.rejected,
                keywords: currentKeywords,
                virtualCopies: currentVirtualCopies
            )
            let copyNumber = base.virtualCopies.count + 1
            let copy = VirtualCopy(
                name: "副本 \(copyNumber)",
                params: params,
                rating: it.rating,
                picked: it.picked,
                colorLabel: it.colorLabel,
                rejected: it.rejected
            )
            base.virtualCopies.append(copy)
            try SidecarStore.write(base, for: it.url)
            workMetrics.increment("sidecarWrite")
            currentVirtualCopies = base.virtualCopies
            let newItem = PhotoItem(
                id: copy.id, url: it.url, rating: copy.rating, picked: copy.picked,
                colorLabel: copy.colorLabel, rejected: copy.rejected,
                virtualCopyID: copy.id, virtualCopyName: copy.name,
                keywords: currentKeywords, cameraModel: it.cameraModel, lensModel: it.lensModel,
                thumb: it.thumb
            )
            let insertIndex = items.lastIndex(where: { $0.url == it.url }).map { $0 + 1 } ?? (currentIndex + 1)
            items.insert(newItem, at: insertIndex)
            select(insertIndex)
            status = "已创建虚拟副本：\(copy.name)"
        } catch {
            workflowError = "创建虚拟副本失败：\(error.localizedDescription)"
        }
    }

    func renameVirtualCopy(_ id: UUID, name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !trimmed.isEmpty, !syncRunning,
              let idx = items.firstIndex(where: { $0.id == id }),
              let vcID = items[idx].virtualCopyID else { return }
        let url = items[idx].url
        do {
            var base = try SidecarStore.read(for: url) ?? Sidecar(params: EditParams())
            if let vIdx = base.virtualCopies.firstIndex(where: { $0.id == vcID }) {
                base.virtualCopies[vIdx].name = trimmed
            }
            try SidecarStore.write(base, for: url)
            workMetrics.increment("sidecarWrite")
            items[idx].virtualCopyName = trimmed
            if idx == currentIndex {
                currentVirtualCopies = base.virtualCopies
                savedSidecarFingerprint = sidecarFingerprint()
            }
            status = "已重命名虚拟副本：\(trimmed)"
        } catch {
            workflowError = "重命名虚拟副本失败：\(error.localizedDescription)"
        }
    }

    func setKeywords(_ list: [String]) {
        guard let it = current, !sidecarReadFailed, !syncRunning else { return }
        let clean = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = clean.filter { seen.insert($0).inserted }
        currentKeywords = unique
        for i in items.indices where items[i].url == it.url {
            items[i].keywords = unique
        }
        saveCurrent()
    }

    func importXMP(from url: URL? = nil) {
        guard let it = current, !sidecarReadFailed, !syncRunning else { return }
        let meta: XMPSidecar.XMPMetadata?
        let sourceDesc: String
        if let url {
            guard let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024 else {
                workflowError = "无法读取 XMP 文件：\(url.lastPathComponent)"
                return
            }
            meta = XMPSidecar.parse(data: data)
            sourceDesc = url.lastPathComponent
        } else {
            meta = XMPSidecar.read(for: it.url)
            sourceDesc = XMPSidecar.url(for: it.url).lastPathComponent
        }
        guard let meta else {
            status = "未找到或无法解析 XMP 旁档：\(sourceDesc)"
            return
        }
        parameterEdits.finishCurrent()
        items[currentIndex].rating = meta.rating
        if meta.hasGoodAttr || !meta.rejected {
            items[currentIndex].picked = meta.hasGoodAttr ? meta.picked : (meta.rating >= 4)
        }
        items[currentIndex].rejected = meta.rejected
        if meta.rejected { items[currentIndex].picked = false }
        if meta.label != .none { items[currentIndex].colorLabel = meta.label }
        if !meta.keywords.isEmpty {
            currentKeywords = meta.keywords
            for i in items.indices where items[i].url == it.url {
                items[i].keywords = meta.keywords
            }
        }
        if meta.hasEdits {
            commit(meta.params)
        } else {
            saveCurrent()
        }
        status = "已导入 XMP：\(sourceDesc)"
    }

    func ensureMultiViewFrame(for item: PhotoItem) {
        if item.id == current?.id { return }
        if multiViewFrames[item.id] != nil || multiViewLoadingIDs.contains(item.id) { return }
        multiViewLoadingIDs.insert(item.id)
        let targetID = item.id
        let url = item.url
        let vcID = item.virtualCopyID
        Task.detached(priority: .userInitiated) {
            let sidecar = SidecarStore.load(for: url) ?? XMPSidecar.read(for: url)?.toSidecar()
            let rp: EditParams
            if let vcID, let vc = sidecar?.virtualCopies.first(where: { $0.id == vcID }) {
                rp = vc.params
            } else {
                rp = sidecar?.params ?? EditParams()
            }
            let src = Engine.decode(url, rawEmbeddedLensCorrection: rp.rawEmbeddedLensCorrection)
            let frame: PreviewFrame?
            if let src {
                let key = PreviewFrameKey(photoID: targetID, revision: 0, purpose: .edited,
                                          paramsFingerprint: PreviewFrame.fingerprint(rp))
                let req = PreviewRequest(key: key, source: src, params: rp, url: url,
                                         fullResolution: false, cropMode: false, longEdge: 1400,
                                         overlayMask: nil, split: false)
                frame = Self.makePreview(req)?.edited
            } else {
                frame = nil
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.multiViewLoadingIDs.remove(targetID)
                if let frame {
                    self.multiViewFrames[targetID] = frame
                    self.multiViewOrder.removeAll { $0 == targetID }
                    self.multiViewOrder.append(targetID)
                    while self.multiViewOrder.count > 8 {
                        let drop = self.multiViewOrder.removeFirst()
                        self.multiViewFrames.removeValue(forKey: drop)
                    }
                }
            }
        }
    }

    func deleteVirtualCopy() {
        guard let it = current, let vcID = it.virtualCopyID, !sidecarReadFailed, !syncRunning else { return }
        let removeIndex = currentIndex
        do {
            var base = try SidecarStore.read(for: it.url) ?? Sidecar(params: EditParams())
            base.virtualCopies.removeAll { $0.id == vcID }
            try SidecarStore.write(base, for: it.url)
            workMetrics.increment("sidecarWrite")
            currentVirtualCopies = base.virtualCopies
            let masterIdx = items.firstIndex(where: { $0.url == it.url && !$0.isVirtualCopy })
            items.remove(at: removeIndex)
            currentIndex = -1
            let target = min(masterIdx ?? removeIndex, items.count - 1)
            if target >= 0 { select(target) }
            status = "已删除虚拟副本"
        } catch {
            workflowError = "删除虚拟副本失败：\(error.localizedDescription)"
        }
    }

    func setReferencePhoto(_ url: URL?) {
        referencePhotoURL = url
        guard let url else { referenceFrame = nil; return }
        let key = PreviewFrameKey(photoID: UUID(), revision: 0, purpose: .edited, paramsFingerprint: "ref")
        let longEdge = previewLongEdge
        Task.detached(priority: .userInitiated) {
            let sidecar = SidecarStore.load(for: url) ?? XMPSidecar.read(for: url)?.toSidecar()
            let rp = sidecar?.params ?? EditParams()
            guard let src = Engine.decode(url, rawEmbeddedLensCorrection: rp.rawEmbeddedLensCorrection) else { return }
            let req = PreviewRequest(key: key, source: src, params: rp, url: url,
                                     fullResolution: false, cropMode: false, longEdge: longEdge,
                                     overlayMask: nil, split: false)
            let res = Self.makePreview(req)
            await MainActor.run { [weak self] in
                guard let self, self.referencePhotoURL == url else { return }
                self.referenceFrame = res?.edited
            }
        }
    }

    func exportCurrentXMP() {
        guard let it = current else { return }
        _ = saveCurrent()
        do {
            let sc = Sidecar(params: params, rating: it.rating, picked: it.picked, snapshots: snapshots,
                             colorLabel: it.colorLabel, rejected: it.rejected,
                             keywords: currentKeywords, virtualCopies: currentVirtualCopies)
            try XMPSidecar.write(sc, for: it.url)
            status = "已导出 XMP：\(XMPSidecar.writeURL(for: it.url).lastPathComponent)"
        } catch {
            workflowError = "导出 XMP 失败：\(error.localizedDescription)"
        }
    }

    func exportFolderXMP() {
        _ = saveCurrent()
        var written = 0
        let masters = items.filter { !$0.isVirtualCopy }
        for it in masters {
            let sc = SidecarStore.load(for: it.url)
                ?? Sidecar(params: EditParams(), rating: it.rating, picked: it.picked,
                           colorLabel: it.colorLabel, rejected: it.rejected, keywords: it.keywords)
            if (try? XMPSidecar.write(sc, for: it.url)) != nil { written += 1 }
        }
        status = "已导出 \(written) 个 XMP 旁档文件"
    }

    func samplePointColor(at normPoint: CGPoint) {
        guard let cg = previewFrame?.image else { return }
        let img = CIImage(cgImage: cg)
        let ext = img.extent
        guard ext.width > 2, ext.height > 2 else { return }
        let px = min(max(Int((normPoint.x * ext.width).rounded()), 0), Int(ext.width) - 1)
        let py = min(max(Int((normPoint.y * ext.height).rounded()), 0), Int(ext.height) - 1)
        let rx = max(0, min(px - 2, Int(ext.width) - 5))
        let ry = max(0, min(py - 2, Int(ext.height) - 5))
        let sampleRect = CGRect(x: rx, y: ry, width: min(5, Int(ext.width)), height: min(5, Int(ext.height)))
        let count = Int(sampleRect.width) * Int(sampleRect.height)
        guard count > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: count * 4)
        Engine.ctx.render(img, toBitmap: &bytes, rowBytes: Int(sampleRect.width) * 4,
                          bounds: sampleRect, format: .RGBA8, colorSpace: Engine.srgb)
        var rSum = 0.0, gSum = 0.0, bSum = 0.0
        for i in 0..<count {
            rSum += Double(bytes[i * 4]) / 255.0
            gSum += Double(bytes[i * 4 + 1]) / 255.0
            bSum += Double(bytes[i * 4 + 2]) / 255.0
        }
        let rgb = [rSum / Double(count), gSum / Double(count), bSum / Double(count)]
        var p = params
        if let maskID = localPointColorMaskID,
           let mIdx = p.masks.firstIndex(where: { $0.id == maskID }) {
            var sw = PointColorSwatch(sampleRGB: rgb, name: p.masks[mIdx].name)
            if let old = p.masks[mIdx].adjust.pointColor {
                sw.hueShift = old.hueShift; sw.chromaShift = old.chromaShift
                sw.lumaShift = old.lumaShift; sw.range = old.range
            }
            p.masks[mIdx].adjust.pointColor = sw
            pointColorPicker = false
            commit(p)
            status = "已为蒙版采样点颜色，可微调局部色相/彩度/明度"
            return
        }
        let sw = PointColorSwatch(sampleRGB: rgb, name: "色样 \(p.pointColors.count + 1)")
        p.pointColors.append(sw)
        pointColorPicker = false
        commit(p)
        status = "已采样点颜色，可微调目标色相/彩度/明度"
    }

    func addRetouchSpot(_ spot: RetouchSpot) {
        var added = spot
        if added.mode != .remove && added.sourceX == nil, let src = source {
            let geo = Engine.geometry(src, params)
            if let suggested = RetouchEngine.suggestSource(for: added, in: geo, workingSpace: Engine.workingColorSpace) {
                added.sourceX = Double(suggested.x)
                added.sourceY = Double(suggested.y)
            }
        }
        var p = params
        p.retouchSpots.append(added)
        selectedRetouchSpotID = added.id
        commit(p)
    }

    func resuggestRetouchSource(_ id: UUID) {
        guard let src = source,
              let i = params.retouchSpots.firstIndex(where: { $0.id == id }) else { return }
        var spot = params.retouchSpots[i]
        guard spot.mode != .remove else { return }
        let geo = Engine.geometry(src, params)
        let oldPt: CGPoint? = (spot.sourceX != nil && spot.sourceY != nil)
            ? CGPoint(x: spot.sourceX!, y: spot.sourceY!) : nil
        if let suggested = RetouchEngine.suggestSource(for: spot, in: geo,
                                                       workingSpace: Engine.workingColorSpace,
                                                       avoiding: oldPt) {
            spot.sourceX = Double(suggested.x)
            spot.sourceY = Double(suggested.y)
            var p = params
            p.retouchSpots[i] = spot
            commit(p)
            status = "已重新挑选干净采样源点"
        }
    }

    func updateRetouchSpotLive(_ spot: RetouchSpot) {
        var p = params
        if let i = p.retouchSpots.firstIndex(where: { $0.id == spot.id }) {
            p.retouchSpots[i] = spot
        }
        params = p
        render()
    }

    func removeRetouchSpot(_ id: UUID) {
        var p = params
        p.retouchSpots.removeAll { $0.id == id }
        if selectedRetouchSpotID == id { selectedRetouchSpotID = nil }
        commit(p)
    }

    // MARK: - P3 单目深度点击对焦 / 参考图反解 / 智能挑片与以图搜图
    func sampleBokehFocus(at normPoint: CGPoint) {
        guard let src = source else { return }
        let geo = Engine.geometry(src, params)
        let disp = current.flatMap { Engine.disparityBokehMask(for: $0.url, target: geo.extent) }
        let painted: CIImage? = params.masks.first(where: { $0.kind == .depth && $0.enabled }).flatMap {
            Engine.maskImage(for: $0, extent: geo.extent, analyzed: geo)
        }
        if let d = DepthEngine.sampleDepth(at: normPoint, in: geo, disparityMask: disp, paintedDepth: painted) {
            var p = params
            p.bokehFocusDepth = d
            if p.bokehAmount <= 0 { p.bokehAmount = 42 }
            bokehFocusPicker = false
            commit(p)
            status = String(format: "已锁定焦平面深度 %.2f", d)
        } else {
            bokehFocusPicker = false
        }
    }

    @discardableResult
    func runColorMatch(referenceURL: URL?, options: ColorMatchOptions = ColorMatchOptions()) -> ColorMatchResult? {
        guard let src = source, let url = referenceURL, let refCI = Engine.decode(url) else {
            status = "未能读取参考图"
            return nil
        }
        let res = ColorMatchEngine.solve(source: src, reference: refCI, base: params, options: options)
        commit(res.params)
        status = String(format: "已匹配参考色调（ΔE %.1f → %.1f，可在面板继续微调）", res.initialDeltaE, res.finalDeltaE)
        return res
    }

    func runSmartCulling() {
        cullingTask?.cancel()
        let masters = items.filter { !$0.isVirtualCopy }
        guard !masters.isEmpty else { return }
        cullingRunning = true
        cullingProgress = 0
        status = "正在运行端侧智能挑片与语义索引…"

        let entriesInput: [(id: UUID, url: URL, date: Date?)] = masters.map { item in
            let dt = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (item.id, item.url, dt)
        }

        cullingTask = Task.detached(priority: .utility) { [weak self] in
            var entries: [(id: UUID, date: Date?, feature: VNFeaturePrintObservation?, metrics: PhotoCullMetrics)] = []
            entries.reserveCapacity(entriesInput.count)
            for (idx, entry) in entriesInput.enumerated() {
                if Task.isCancelled { return }
                let result: (PhotoCullMetrics, VNFeaturePrintObservation?) = autoreleasepool {
                    if let cg = Self.loadCGForCulling(entry.url) {
                        if let cached = SmartCullingEngine.cachedMetrics(for: entry.url) {
                            let fp = SmartCullingEngine.featurePrint(for: cg)
                            return (cached, fp)
                        }
                        let analyzed = SmartCullingEngine.analyzeImage(cg, captureDate: entry.date)
                        SmartCullingEngine.saveCachedMetrics(analyzed.metrics, for: entry.url)
                        return analyzed
                    }
                    return (PhotoCullMetrics(), nil)
                }
                entries.append((entry.id, entry.date, result.1, result.0))
                let prog = Double(idx + 1) / Double(max(entriesInput.count, 1))
                let metricsSnap = result.0
                let fpSnap = result.1
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.cullMetrics[entry.id] = metricsSnap
                    if let fp = fpSnap { self.cullFeatureCache[entry.id] = fp }
                    self.cullingProgress = prog
                    self.status = "智能挑片分析 \(idx + 1)/\(entriesInput.count)"
                }
            }

            if Task.isCancelled { return }
            let grouped = SmartCullingEngine.assignBurstGroups(entries: entries)
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, m) in grouped {
                    self.cullMetrics[id] = m
                }
                self.cullingRunning = false
                self.cullingProgress = 1.0
                let closed = grouped.values.filter(\.eyesClosed).count
                let blurry = grouped.values.filter(\.isBlurry).count
                let bursts = grouped.values.filter(\.isBurstBest).count
                self.status = "智能挑片完成：连拍最佳 \(bursts) · 闭眼 \(closed) · 模糊 \(blurry)"
            }
        }
    }

    func cancelSmartCulling() {
        cullingTask?.cancel()
        cullingTask = nil
        cullingRunning = false
        status = "已取消智能挑片"
    }

    func applyCullBestPicks() {
        var cnt = 0
        for it in items where !it.isVirtualCopy {
            if let m = cullMetrics[it.id], !m.eyesClosed, !m.isBlurry, (m.isBurstBest || m.overallScore >= 68) {
                if !it.picked { togglePick(for: it.id); cnt += 1 }
            }
        }
        status = "已自动标记 \(cnt) 张智能最佳照片为精选"
    }

    func rejectCullDefects() {
        var cnt = 0
        for it in items where !it.isVirtualCopy {
            if let m = cullMetrics[it.id], m.eyesClosed || m.isBlurry {
                if !it.rejected { toggleReject(for: it.id); cnt += 1 }
            }
        }
        status = "已淘汰 \(cnt) 张闭眼/跑焦照片"
    }

    func findSimilarPhotos(to targetID: UUID) {
        guard let target = items.first(where: { $0.id == targetID }) else { return }
        status = "正在检索视觉相似照片…"
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let existingFeatures = await MainActor.run { self.cullFeatureCache }
            let allItems = await MainActor.run { self.items }

            let targetFP: VNFeaturePrintObservation? = existingFeatures[targetID] ?? {
                guard let cg = Self.loadCGForCulling(target.url) else { return nil }
                return SmartCullingEngine.featurePrint(for: cg)
            }()
            guard let tFP = targetFP else {
                await MainActor.run { self.status = "无法提取目标特征" }
                return
            }

            var pairs: [(id: UUID, feature: VNFeaturePrintObservation)] = []
            for it in allItems where !it.isVirtualCopy {
                if let cached = existingFeatures[it.id] {
                    pairs.append((it.id, cached))
                } else if let cg = Self.loadCGForCulling(it.url),
                          let fp = SmartCullingEngine.featurePrint(for: cg) {
                    pairs.append((it.id, fp))
                }
            }
            let ordered = SemanticSearchEngine.rankSimilar(target: tFP, candidates: pairs)
            let finalPairs = pairs
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, fp) in finalPairs { self.cullFeatureCache[id] = fp }
                self.similarPhotoTargetID = targetID
                self.similarPhotoOrder = ordered
                self.status = "已按与 \(target.displayName) 的视觉相似度排序（\(ordered.count) 张）"
            }
        }
    }

    func clearSimilarFilter() {
        similarPhotoTargetID = nil
        similarPhotoOrder = []
    }

    nonisolated private static func loadCGForCulling(_ url: URL) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCache: false
        ]
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return thumb
        }
        guard let ci = Engine.decode(url) else { return nil }
        let s = min(1.0, 512.0 / max(ci.extent.width, ci.extent.height, 1.0))
        let small = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return Engine.ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: Engine.srgb)
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
                    if state.folder == nil { WorkspaceReviewBench.launchBegin = ProcessInfo.processInfo.systemUptime; state.openFolder(QAWorkspace.fixtureFolder) }
                }
                #endif
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            #if PHOS_QA
            CommandMenu("QA") {
                Button("平台基线检查…") { QAPlatformBaselineController.shared.show() }

                Button("切换工作区应急材料") {
                    let defaults = UserDefaults.standard
                    defaults.set(!defaults.bool(forKey: "phos.ui.disableNativeGlass"), forKey: "phos.ui.disableNativeGlass")
                }
                Menu("验收窗口尺寸") {
                    ForEach([1200,1440,1728],id:\.self) { width in
                        Button("宽 \(width)") { NSApp.keyWindow?.setContentSize(NSSize(width:width,height:900)) }
                    }
                }
                Button("测试工作区错误提示") { state.workflowError = "R2-A QA：窗口级错误路由验证。" }
            }
            #endif
            WorkspaceMenuCommands(state: state, history: state.history)
        }
    }

}
#endif
