import SwiftUI
import CoreImage
import UniformTypeIdentifiers

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

    // 编辑
    @Published var params = EditParams()
    @Published var source: CIImage?
    @Published var preview: CGImage?
    @Published var previewing: Bool = false
    @Published var showBefore: Bool = false
    @Published var beforeImage: CGImage?
    @Published var hist: (r: [Int], g: [Int], b: [Int], l: [Int]) = ([], [], [], [])
    @Published var status: String = "准备就绪"
    @Published var selectedMask: UUID?
    @Published var zoom: Double = 1
    @Published var cropMode = false   // 裁剪模式：画布显示未裁剪图 + 裁剪框

    // 预览精度：默认走 2200px 代理图求快；打开后走全像素
    @Published var fullResPreview: Bool = false
    @Published var oneToOne: Bool = false
    @Published var sourceSize: CGSize = .zero
    @Published var lastPreviewScale: Double = 1

    // 导出
    @Published var exportSettings = ExportSettings()
    @Published var showExport = false
    @Published var showBatch = false
    @Published var batchRunning = false
    @Published var batchProgress: Double = 0

    // 多重曝光合成
    @Published var showMerge = false
    @Published var mergeMode: MergeMode = .fusion
    @Published var mergeRunning = false
    @Published var mergeProgress: String = ""

    let history = History()
    let cluts = CLUTLibrary.shared

    private var renderTask: Task<Void, Never>?
    private var sourceCache: [URL: CIImage] = [:]
    private let previewLongEdge: CGFloat = 2200

    var current: PhotoItem? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    // MARK: - 打开文件夹
    func openFolder(_ url: URL) {
        folder = url
        let fm = FileManager.default
        let exts = Engine.browseSet
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
        let imgs = files.filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        items = imgs.map { u in
            var it = PhotoItem(url: u)
            if let sc = SidecarStore.load(for: u) {
                it.rating = sc.rating
                it.picked = sc.picked
            }
            return it
        }
        status = "共 \(items.count) 张"
        if !items.isEmpty { select(0) }
        Task { await makeThumbs() }
    }

    private func makeThumbs() async {
        for i in items.indices {
            let u = items[i].url
            let img = await Task.detached { Self.thumb(for: u) }.value
            if let cg = img, i < items.count {
                items[i].thumb = cg
            }
        }
    }

    nonisolated static func thumb(for url: URL) -> CGImage? {
        guard let ci = Engine.decode(url) else { return nil }
        let e = ci.extent
        let s = min(1, 260 / max(e.width, e.height))
        let small = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return Engine.ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: Engine.srgb)
    }

    // MARK: - 选图
    func select(_ i: Int) {
        guard i >= 0, i < items.count else { return }
        saveCurrent()
        currentIndex = i
        let u = items[i].url
        let ci: CIImage? = sourceCache[u] ?? {
            let src = Engine.decode(u)
            sourceCache[u] = src
            return src
        }()
        source = ci
        sourceSize = ci?.extent.size ?? .zero
        if let sc = SidecarStore.load(for: u) {
            params = sc.params
        } else {
            params = EditParams()
        }
        history.stack = [params]; history.index = 0
        selectedMask = nil
        render()
    }

    // MARK: - 参数改动
    func commit(_ p: EditParams) {
        params = p
        history.push(p)
        render()
        autoSave()
    }

    func undo() {
        if let p = history.undo() { params = p; render(); autoSave() }
    }
    func redo() {
        if let p = history.redo() { params = p; render(); autoSave() }
    }

    func autoSave() { saveCurrent() }

    func saveCurrent() {
        guard let it = current else { return }
        let sc = Sidecar(params: params, rating: items[currentIndex].rating, picked: items[currentIndex].picked)
        SidecarStore.save(sc, for: it.url)
    }

    func setRating(_ r: Int) {
        guard currentIndex < items.count else { return }
        items[currentIndex].rating = r
        saveCurrent()
    }
    func togglePick() {
        guard currentIndex < items.count else { return }
        items[currentIndex].picked.toggle()
        saveCurrent()
    }

    // MARK: - 裁剪模式辅助
    func toggleCropMode() {
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
        status = "检测地平线…"
        Task {
            let angle = await Task.detached { Engine.autoStraightenAngle(from: src) }.value
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
        renderTask?.cancel()
        previewing = true
        // 裁剪模式下预览未裁剪的整幅（裁剪框叠加层直接在画布上改），退出后恢复
        let p = cropMode ? params.cropNeutral : params
        let longEdge = previewLongEdge
        let needFull = fullResPreview || oneToOne
        renderTask = Task.detached(priority: .userInitiated) {
            let e = src.extent
            let s: CGFloat = needFull ? 1.0 : min(1, longEdge / max(e.width, e.height))
            let base = s < 1 ? src.transformed(by: CGAffineTransform(scaleX: s, y: s)) : src
            let out = Engine.render(base, p)
            let cg = Engine.ctx.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: Engine.srgb)
            let h = Engine.histogram(out)
            await MainActor.run {
                self.preview = cg
                self.hist = h
                self.lastPreviewScale = Double(s)
                self.previewing = false
            }
        }
    }

    func refreshBefore() {
        guard let src = source else { return }
        let e = src.extent
        let s = min(1, previewLongEdge / max(e.width, e.height))
        let base = s < 1 ? src.transformed(by: CGAffineTransform(scaleX: s, y: s)) : src
        beforeImage = Engine.ctx.createCGImage(base, from: base.extent, format: .RGBA8, colorSpace: Engine.srgb)
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

        let dest: URL? = await Task.detached(priority: .userInitiated) {
            var frames: [CIImage] = []
            for u in urls {
                autoreleasepool {
                    if let ci = Engine.decode(u) { frames.append(ci) }
                }
            }
            guard frames.count >= 2, let merged = Engine.fuse(frames, mode: mode) else { return nil }
            let first = urls[0].deletingPathExtension()
            let out = first.deletingLastPathComponent()
                .appendingPathComponent(first.lastPathComponent + "_合成.tif")
            do { try Engine.write16(merged, to: out); return out } catch { return nil }
        }.value

        guard let out = dest else {
            mergeRunning = false
            mergeProgress = ""
            status = "合成失败（解码或写盘出错）"
            return
        }

        // 结果若在当前文件夹里，插进列表并选中
        if let f = folder, out.deletingLastPathComponent().standardizedFileURL == f.standardizedFileURL {
            var it = PhotoItem(url: out)
            if let sc = SidecarStore.load(for: out) { it.rating = sc.rating; it.picked = sc.picked }
            items.append(it)
            items.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            if let idx = items.firstIndex(where: { $0.url == out }) {
                select(idx)
                let u = out
                let cg = await Task.detached { Self.thumb(for: u) }.value
                if let cg, idx < items.count { items[idx].thumb = cg }
            }
        }
        mergeRunning = false
        mergeProgress = ""
        showMerge = false
        status = "已合成 \(urls.count) 张 → \(out.lastPathComponent)"
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
        guard let src = source else { return }
        let out = Engine.render(src, params)
        do {
            try Engine.write(out, to: url, settings: exportSettings)
            status = "已导出 \(url.lastPathComponent)"
        } catch {
            status = "导出失败：\(error.localizedDescription)"
        }
    }

    func batchExport(to dir: URL, onlyPicked: Bool) async {
        batchRunning = true
        batchProgress = 0
        let list = items.filter { !onlyPicked || $0.picked }
        for (i, it) in list.enumerated() {
            autoreleasepool {
                if let src = Engine.decode(it.url) {
                    let sc = SidecarStore.load(for: it.url)
                    let p = sc?.params ?? EditParams()
                    let out = Engine.render(src, p)
                    let ext = exportSettings.format
                    let dest = dir.appendingPathComponent(it.url.deletingPathExtension().lastPathComponent + ".\(ext)")
                    try? Engine.write(out, to: dest, settings: exportSettings)
                }
            }
            await MainActor.run { self.batchProgress = Double(i + 1) / Double(max(list.count, 1)) }
        }
        await MainActor.run {
            self.batchRunning = false
            self.status = "批量导出完成：\(list.count) 张"
        }
    }
}

@main
struct RawForgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(state)
                .frame(minWidth: 1280, minHeight: 820)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { state.undo() }.keyboardShortcut("z", modifiers: .command)
                Button("重做") { state.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("打开文件夹…") { openPanel(state) }.keyboardShortcut("o")
                Button("导出当前照片…") { state.showExport = true }.keyboardShortcut("e")
                Button("多重曝光合成…") { state.showMerge = true }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("前后对比") { state.showBefore.toggle() }.keyboardShortcut("b")
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
