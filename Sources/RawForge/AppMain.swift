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
    var visiblePhotoIndices: [Int] {
        items.indices.filter {
            (filterRating == 0 || items[$0].rating >= filterRating) &&
            (!filterPicked || items[$0].picked)
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
    @Published var showMaskOverlay = false {
        didSet { if oldValue != showMaskOverlay { previewQueue.invalidate(); render() } }
    }
    @Published var maskTool: MaskTool = .position
    @Published var brushRadius: Double = 0.05
    @Published var brushFeather: Double = 0.5
    @Published var maskPreviewImage: CGImage?
    private var sidecarReadFailed = false

    // 编辑
    @Published var params = EditParams()
    @Published var source: CIImage?
    @Published var preview: CGImage?
    @Published var previewing: Bool = false
    @Published var showBefore: Bool = false {
        didSet { if showBefore { refreshBefore() } }
    }
    @Published var beforeImage: CGImage?
    @Published var hist: (r: [Int], g: [Int], b: [Int], l: [Int]) = ([], [], [], [])
    @Published var status: String = "准备就绪"
    @Published var selectedMask: UUID? {
        didSet {
            if oldValue != selectedMask {
                maskPreviewImage = nil
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
        didSet { if oldValue != oneToOne { previewQueue.invalidate(); render() } }
    }
    @Published var sourceSize: CGSize = .zero
    @Published var lastPreviewScale: Double = 1

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

    let history = History()
    let cluts = CLUTLibrary.shared

    private var thumbnailTask: Task<Void, Never>?
    private let sourceCache = BoundedCache<URL, CIImage>(capacity: 3)
    private let previewLongEdge: CGFloat = 2200
    private struct PhotoLoad {
        let url: URL
        let cached: CIImage?
    }
    private struct PreviewRequest {
        let source: CIImage
        let params: EditParams
        let url: URL?
        let fullResolution: Bool
        let cropMode: Bool
        let longEdge: CGFloat
        let overlayMask: UUID?
    }
    private struct PreviewResult {
        let image: CGImage
        let histogram: (r: [Int], g: [Int], b: [Int], l: [Int])
        let scale: Double
        let mask: CGImage?
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
            guard let result else { self.status = "无法读取文件夹"; return }
            self.items = result
            self.status = result.isEmpty ? "文件夹里没有支持的图像" : "共 \(result.count) 张"
            if !result.isEmpty { self.select(0) }
            self.loadThumbnails()
        })
    private lazy var sourceQueue = LatestWorkQueue<PhotoLoad, (CIImage?, Bool)>(
        operation: { request in
            (request.cached ?? Engine.decode(request.url), Engine.hasDisparity(request.url))
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
    private lazy var previewQueue: LatestWorkQueue<PreviewRequest, PreviewResult?> = LatestWorkQueue(
        operation: { Self.makePreview($0) },
        completion: { [weak self] request, result in
            guard let self, request.url == self.current?.url,
                  request.cropMode == self.cropMode,
                  request.fullResolution == (self.fullResPreview || self.oneToOne) else { return }
            if let result {
                self.preview = result.image
                self.hist = result.histogram
                self.lastPreviewScale = result.scale
                if request.overlayMask == (self.showMaskOverlay ? self.selectedMask : nil) {
                    self.maskPreviewImage = result.mask
                }
            }
            self.previewing = self.previewQueue.hasPendingWork
        })
    private lazy var beforeQueue = LatestWorkQueue<CIImage, CGImage?>(
        operation: { image in
            let scale = min(1, 2200 / max(image.extent.width, image.extent.height))
            let base = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return Engine.ctx.createCGImage(base, from: base.extent, format: .RGBA8, colorSpace: Engine.srgb)
        },
        completion: { [weak self] _, image in self?.beforeImage = image })

    var current: PhotoItem? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    // MARK: - 打开文件夹
    func openFolder(_ url: URL) {
        guard !syncRunning, saveCurrent() else { return }
        folderQueue.invalidate()
        sourceQueue.invalidate()
        previewQueue.invalidate()
        beforeQueue.invalidate()
        thumbnailTask?.cancel()
        currentIndex = -1
        source = nil
        preview = nil
        beforeImage = nil
        sourceSize = .zero
        hasDisparity = false
        previewing = false
        hist = ([], [], [], [])
        items = []
        selectedPhotos = []
        snapshots = []
        selectedMask = nil
        whiteBalancePicker = false
        sourceCache.removeAll()
        folder = url
        status = "正在读取文件夹…"
        folderQueue.submit(url)
    }

    private func loadThumbnails() {
        thumbnailTask?.cancel()
        let photos = items.map { (id: $0.id, url: $0.url) }
        thumbnailTask = Task { [weak self] in
            var batch: [(UUID, CGImage)] = []
            var lastUpdate = Date()
            for (offset, photo) in photos.enumerated() {
                guard !Task.isCancelled else { return }
                let image = await Task.detached(priority: .utility) {
                    autoreleasepool { Self.thumb(for: photo.url) }
                }.value
                guard !Task.isCancelled, let self else { return }
                if let image { batch.append((photo.id, image)) }
                if batch.count >= 12 || Date().timeIntervalSince(lastUpdate) >= 0.1 || offset == photos.count - 1 {
                    let indices = Dictionary(uniqueKeysWithValues: self.items.enumerated().map { ($0.element.id, $0.offset) })
                    var updated = self.items
                    for (id, image) in batch {
                        if let index = indices[id] { updated[index].thumb = image }
                    }
                    if !batch.isEmpty { self.items = updated }
                    batch.removeAll(keepingCapacity: true)
                    lastUpdate = Date()
                }
            }
        }
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
    func select(_ i: Int) {
        guard !syncRunning, i >= 0, i < items.count, saveCurrent() else { return }
        sourceQueue.invalidate()
        previewQueue.invalidate()
        beforeQueue.invalidate()
        currentIndex = i
        let u = items[i].url
        source = nil
        preview = nil
        beforeImage = nil
        sourceSize = .zero
        hist = ([], [], [], [])
        previewing = true
        hasDisparity = false
        whiteBalancePicker = false
        sidecarReadFailed = false
        do {
            let sc = try SidecarStore.read(for: u)
            params = sc?.params ?? EditParams()
            snapshots = sc?.snapshots ?? []
        } catch {
            sidecarReadFailed = true
            snapshots = []
            selectedMask = nil
            previewing = false
            workflowError = "无法读取 \(u.lastPathComponent) 的编辑记录，原文件未修改。\n\(error.localizedDescription)"
            return
        }
        history.stack = [params]; history.index = 0
        selectedMask = nil
        sourceQueue.submit(PhotoLoad(url: u, cached: sourceCache[u]))
    }

    // MARK: - 参数改动
    func commit(_ p: EditParams) {
        guard !syncRunning else { return }
        params = p
        history.push(p)
        render()
        autoSave()
    }

    func undo() {
        guard !syncRunning else { return }
        if let p = history.undo() { params = p; render(); autoSave() }
    }
    func redo() {
        guard !syncRunning else { return }
        if let p = history.redo() { params = p; render(); autoSave() }
    }

    func autoSave() { saveCurrent() }

    @discardableResult
    func saveCurrent() -> Bool {
        guard !sidecarReadFailed, let it = current else { return true }
        let sc = Sidecar(params: params, rating: it.rating, picked: it.picked, snapshots: snapshots)
        do {
            try SidecarStore.write(sc, for: it.url)
            return true
        } catch {
            workflowError = "编辑记录保存失败：\(it.url.lastPathComponent)\n\(error.localizedDescription)"
            return false
        }
    }

    func setRating(_ r: Int) {
        guard current != nil else { return }
        items[currentIndex].rating = r
        saveCurrent()
    }
    func togglePick() {
        guard current != nil else { return }
        items[currentIndex].picked.toggle()
        saveCurrent()
    }

    // MARK: - 裁剪模式辅助
    func toggleCropMode() {
        guard source != nil else { return }
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
        previewQueue.submit(PreviewRequest(source: src, params: cropMode ? params.cropNeutral : params,
                                           url: current?.url, fullResolution: fullResPreview || oneToOne,
                                           cropMode: cropMode, longEdge: previewLongEdge,
                                           overlayMask: showMaskOverlay && !cropMode ? selectedMask : nil))
    }

    nonisolated private static func makePreview(_ request: PreviewRequest) -> PreviewResult? {
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
        return PreviewResult(image: image, histogram: histogram, scale: Double(scale), mask: maskCG)
    }

    func refreshBefore() {
        guard beforeImage == nil, let src = source else { return }
        beforeQueue.submit(src)
    }

    // MARK: - 蒙版
    func addMask(_ kind: MaskKind) {
        var m = Mask()
        m.kind = kind
        m.name = kind.label
        var p = params
        p.masks.append(m)
        selectedMask = m.id
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("RawForge/presets.json")
    }
    func loadPresets() -> [Preset] {
        guard let d = try? Data(contentsOf: presetsURL),
              let ps = try? JSONDecoder().decode([Preset].self, from: d) else { return defaultPresets }
        return ps
    }
    func savePresets(_ ps: [Preset]) {
        let dir = presetsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(ps) { try? d.write(to: presetsURL) }
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

#if !RAWFORGE_TESTING
@main
struct RawForgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            StudioMainWindow()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { state.undo() }.keyboardShortcut("z", modifiers: .command)
                Button("重做") { state.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("打开文件夹…") { openPanel(state) }.keyboardShortcut("o")
                Button("导出当前照片…") { state.showExport = true }.keyboardShortcut("e")
                Button("裁剪") { state.toggleCropMode() }.keyboardShortcut("r")
                Button("批量导出…") { state.showBatch = true }
                Button("多重曝光合成…") { state.showMerge = true }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("前后对比") { state.showBefore.toggle() }.keyboardShortcut("b")
                Button("复制调整") { state.copyAdjustments() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("同步调整…") { state.showSync = true }.keyboardShortcut("v", modifiers: [.command, .shift])
                Button("命名快照…") { state.showSnapshots = true }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }

    func openPanel(_ s: AppState) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        if p.runModal() == .OK, let u = p.url { s.openFolder(u) }
    }
}
#endif
