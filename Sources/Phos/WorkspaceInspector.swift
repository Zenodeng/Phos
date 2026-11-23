import SwiftUI
import ImageIO
import CoreImage
import UniformTypeIdentifiers

struct WorkspaceInspector: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    @ObservedObject private var ui: WorkspaceInspectorState
    @State private var confirmReset = false
    init(state: AppState) { self.state = state; ui = state.inspectorUI }
    var body: some View {
        VStack(spacing:0) {
            VStack(spacing:5) {
                HStack {
                    Text(L10n.tr(state.showBefore ? "原图" : state.cropMode ? "裁剪参考" : "调整后"))
                    Spacer()
                    if state.previewing { ProgressView().controlSize(.mini) }
                    Text(L10n.tr("RGB")).monospaced()
                }.font(.system(size:10,weight:.medium)).foregroundStyle(WorkspaceTokens.secondaryText)
                HistogramView(bins:state.hist).frame(height:46)
                    .accessibilityLabel(L10n.tr("当前照片 RGB 直方图"))
            }.padding(.horizontal,12).padding(.top,12).padding(.bottom,10)
            HStack(spacing:4) {
                Button { state.parameterEdits.finishCurrent(); state.showPhotoAI = true } label: {
                    Label(L10n.tr("AI 修图"),systemImage:"sparkles").font(.system(size:11))
                }.buttonStyle(WorkspaceButtonStyle()).disabled(state.source == nil).help(L10n.tr("用本地模型调整照片"))
                Spacer()
                Button { state.parameterEdits.invalidate(); confirmReset = true } label: {
                    Image(systemName:"arrow.counterclockwise").font(.system(size:12)).frame(width:18,height:18)
                }.buttonStyle(WorkspaceButtonStyle()).disabled(state.source == nil).help(L10n.tr("恢复所有默认参数")).accessibilityLabel(L10n.tr("恢复所有默认参数"))
                Button { state.parameterEdits.finishCurrent(); ui.showPresets.toggle() } label: {
                    Label(L10n.tr("预设"),systemImage:"square.grid.2x2").font(.system(size:11)).frame(height:18)
                }.buttonStyle(WorkspaceButtonStyle(selected:ui.showPresets)).help(L10n.tr("浏览预设"))
                    .popover(isPresented:$ui.showPresets,arrowEdge:.leading) {
                        WorkspacePresetBrowser().environmentObject(state)
                    }
                Button { ui.showInformation.toggle() } label: {
                    Image(systemName:"info.circle").font(.system(size:13)).frame(width:18,height:18)
                }.buttonStyle(WorkspaceButtonStyle(selected:ui.showInformation)).help(L10n.tr("照片信息")).accessibilityLabel(L10n.tr("照片信息"))
                    .popover(isPresented:$ui.showInformation,arrowEdge:.leading) {
                        WorkspacePhotoInformation().environmentObject(state)
                    }
            }.padding(.horizontal,10).frame(height:36)
            Divider()
            InspectorPane(transparent:true,ui:ui).disabled(state.source == nil)
        }.environmentObject(ui)
            .alert(L10n.tr("恢复所有默认参数？"),isPresented:$confirmReset) {
                Button(L10n.tr("取消"),role:.cancel) {}
                Button(L10n.tr("恢复默认"),role:.destructive) { state.selectedMask = nil; state.commit(EditParams()) }
            } message: { Text(L10n.tr("此操作可撤销，原始照片不会改变。")) }
    }
}

@MainActor private final class PresetPreviewModel: ObservableObject {
    struct Request { let source: CIImage; let params: EditParams; let photoID: UUID?; let presetID: UUID }
    @Published var image: CGImage?
    @Published var busy = false
    @Published var failed = false
    private var expected: UUID?
    private lazy var queue = LatestWorkQueue<Request,CGImage?>(operation:{ request in
        let e = request.source.extent, scale = min(1,480/max(e.width,e.height))
        let small = request.source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let output = Engine.render(small,request.params)
        return Engine.ctx.createCGImage(output,from:output.extent,format:.RGBA8,colorSpace:Engine.srgb)
    },completion:{ [weak self] request, image in
        guard let self, expected == request.presetID else { return }
        self.image = image; busy = false; failed = image == nil
    })
    func show(_ preset: Preset?, source: CIImage?, photoID: UUID?) {
        queue.invalidate(); expected = preset?.id; image = nil; failed = false
        guard let preset, let source else { busy = false; return }
        busy = true; queue.submit(Request(source:source,params:preset.params,photoID:photoID,presetID:preset.id))
    }
}

struct WorkspacePresetCatalog {
    let presets:[Preset]
    let error:String?
    static func load(_ url:URL, fallback:[Preset]) -> Self {
        guard FileManager.default.fileExists(atPath:url.path) else { return Self(presets:fallback,error:nil) }
        do { return Self(presets:try JSONDecoder().decode([Preset].self,from:Data(contentsOf:url)),error:nil) }
        catch { return Self(presets:fallback,error:"预设文件无法读取，已保留原文件。可使用内置预设。") }
    }
}

enum PresetCollection: String, CaseIterable { case all = "全部", builtin = "内置", personal = "我的预设" }
enum WorkspacePresetPolicy {
    static func filtered(_ presets:[Preset], query:String, collection:PresetCollection) -> [Preset] {
        let q = query.trimmingCharacters(in:.whitespacesAndNewlines)
        return presets.filter { (collection == .all || ($0.builtin ? collection == .builtin : collection == .personal)) && (q.isEmpty || $0.name.localizedStandardContains(q) || ($0.builtin && L10n.tr($0.name).localizedStandardContains(q))) }
    }
}

struct WorkspacePresetBrowser: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject private var s: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = PresetPreviewModel()
    @State private var query = ""
    @State private var name = ""
    @State private var catalogError: String?
    @State private var importNote: String?
    @State private var collection: PresetCollection = .all
    @State private var presets: [Preset] = []
    @State private var selection: UUID?
    @State private var hoveredID: UUID?
    @State private var amount: Double = 1.0
    private var selected: Preset? { presets.first { $0.id == selection } }
    private var activePreviewTarget: Preset? { presets.first { $0.id == (hoveredID ?? selection) } }
    private var shown: [Preset] { WorkspacePresetPolicy.filtered(presets,query:query,collection:collection) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(L10n.tr("预设")).font(.system(size:16,weight:.semibold))
                Spacer()
                Button(L10n.tr("导入 LR .xmp…")) { importLRPresets() }
                    .controlSize(.small)
                Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker(L10n.tr("集合"),selection:$collection) { ForEach(PresetCollection.allCases,id:\.self) { Text(L10n.tr($0.rawValue)).tag($0) } }.pickerStyle(.segmented)
            TextField(L10n.tr("搜索预设"),text:$query).textFieldStyle(.roundedBorder)
            if let catalogError { Label(L10n.tr(catalogError),systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(WorkspaceTokens.error).fixedSize(horizontal:false,vertical:true) }
            if let importNote { Text(importNote).font(.caption).foregroundStyle(WorkspaceTokens.secondaryText) }
            HStack(alignment:.top,spacing:12) {
                ScrollView {
                    LazyVStack(spacing:3) {
                        ForEach(shown) { preset in
                            Button { selection = preset.id; refreshPreview() } label: {
                                HStack(spacing:7) {
                                    Image(systemName:preset.builtin ? "sparkles" : "person.crop.square").frame(width:16)
                                    Text(preset.builtin ? L10n.tr(preset.name) : preset.name).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                                    if selection == preset.id { Image(systemName:"checkmark").font(.caption) }
                                }.font(.system(size:12)).padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .background((selection == preset.id || hoveredID == preset.id) ? WorkspaceTokens.accent.opacity(selection == preset.id ? 0.14 : 0.06) : .clear,in:RoundedRectangle(cornerRadius:6))
                                .accessibilityAddTraits(selection == preset.id ? .isSelected : [])
                                .onHover { inside in
                                    if inside {
                                        hoveredID = preset.id
                                        refreshPreview()
                                    } else if hoveredID == preset.id {
                                        hoveredID = nil
                                        refreshPreview()
                                    }
                                }
                        }
                        if shown.isEmpty { Text(L10n.tr("没有匹配的预设")).font(.caption).foregroundStyle(WorkspaceTokens.secondaryText).padding(.vertical,30) }
                    }
                }.frame(width:154,height:200)
                VStack(spacing:8) {
                    ZStack {
                        RoundedRectangle(cornerRadius:8).fill(WorkspaceTokens.chartColor)
                        if let image = preview.image { Image(decorative:image,scale:1).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius:8)) }
                        else if preview.busy { ProgressView() }
                        else { Text(L10n.tr(preview.failed ? "无法生成预览" : "选择预设以预览")).font(.caption).foregroundStyle(WorkspaceTokens.secondaryText) }
                    }.frame(width:228,height:170)
                    Text(activePreviewTarget.map { $0.builtin ? L10n.tr($0.name) : $0.name } ?? L10n.tr("当前照片预览"))
                        .font(.caption).foregroundStyle(WorkspaceTokens.secondaryText).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                Text(L10n.tr("预设强度"))
                    .font(.system(size: 11)).foregroundStyle(WorkspaceTokens.secondaryText)
                Slider(value: $amount, in: 0...2.0, step: 0.05) { _ in }
                    .controlSize(.small)
                    .onChange(of: amount) { _, _ in refreshPreview() }
                Text("\(Int((amount * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 42, alignment: .trailing)
            }
            HStack {
                TextField(L10n.tr("保存当前调整为新预设"),text:$name).textFieldStyle(.roundedBorder)
                Button(L10n.tr("保存")) {
                    let preset = Preset(name:String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(120)),params:s.params)
                    if s.savePresets(presets+[preset]) { presets.append(preset); name = ""; catalogError = nil }
                }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || s.source == nil || catalogError != nil)
            }
            HStack { Text(L10n.tr("预览不会改动照片")).font(.caption).foregroundStyle(WorkspaceTokens.secondaryText); Spacer()
                Button(L10n.tr("取消"),role:.cancel) { dismiss() }
                Button(L10n.tr("应用预设")) {
                    if let selected {
                        s.commit(selected.params.scaled(by: amount))
                        dismiss()
                    }
                }
                    .buttonStyle(WorkspaceButtonStyle(prominent:true)).keyboardShortcut(.defaultAction).disabled(selected == nil || s.source == nil || s.syncRunning)
            }
        }.padding(16).frame(width:438).workspaceGlassPanel()
            .onAppear { load() }
            .onChange(of:s.current?.id) { _, _ in refreshPreview() }
    }
    private func load() {
        let catalog = WorkspacePresetCatalog.load(s.presetsURL,fallback:s.loadPresets())
        presets = catalog.presets; catalogError = catalog.error
    }
    private func refreshPreview() {
        if let target = activePreviewTarget {
            let scaled = Preset(id: target.id, name: target.name, params: target.params.scaled(by: amount), builtin: target.builtin)
            preview.show(scaled, source: s.source, photoID: s.current?.id)
        } else {
            preview.show(nil, source: s.source, photoID: s.current?.id)
        }
    }
    private func importLRPresets() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        if let xmpType = UTType(filenameExtension: "xmp") {
            p.allowedContentTypes = [xmpType]
        }
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        var imported: [Preset] = []
        for url in p.urls {
            if let preset = XMPSidecar.parsePreset(from: url) {
                imported.append(preset)
            }
        }
        guard !imported.isEmpty else {
            importNote = L10n.tr("未从所选 XMP 中解析出有效调色预设")
            return
        }
        let next = presets + imported
        if s.savePresets(next) {
            presets = next
            selection = imported.last?.id
            catalogError = nil
            importNote = L10n.tr("已导入 \(imported.count) 个 XMP 预设")
            refreshPreview()
        }
    }
}

struct WorkspacePhotoInformation: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject private var s: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var metadata: [String:String] = [:]
    @State private var newKeyword: String = ""
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(L10n.tr("照片信息")).font(.system(size:16,weight:.semibold)); Spacer(); Button(L10n.tr("完成")) { dismiss() } }
            Text(s.current?.url.lastPathComponent ?? "未选择照片").font(.system(size:13,weight:.medium)).textSelection(.enabled)
            information("原图尺寸",value:s.sourceSize.width > 0 ? "\(Int(s.sourceSize.width)) × \(Int(s.sourceSize.height))" : "—")
            information("当前输出",value:s.displayFrame.map { "\(Int($0.editedExtent.width)) × \(Int($0.editedExtent.height))" } ?? "—")
            information("预览",value:s.displayFrame.map { "\($0.image.width) × \($0.image.height) · \($0.fullResolution ? "完整" : "代理")" } ?? "—")
            ForEach(["相机","镜头","ISO","快门","光圈","拍摄时间"],id:\.self) { key in information(key,value:metadata[key] ?? "—") }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("关键词")).font(.system(size: 11, weight: .semibold)).foregroundStyle(WorkspaceTokens.secondaryText)
                if !s.currentKeywords.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(s.currentKeywords, id: \.self) { kw in
                                HStack(spacing: 3) {
                                    Text(kw).font(.system(size: 10.5))
                                    Button {
                                        s.setKeywords(s.currentKeywords.filter { $0 != kw })
                                    } label: {
                                        Image(systemName: "xmark").font(.system(size: 8))
                                    }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(WorkspaceTokens.accent.opacity(0.14), in: Capsule())
                            }
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField(L10n.tr("添加关键词（回车保存）"), text: $newKeyword)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { addKeyword() }
                        .disabled(s.current == nil)
                    Button(L10n.tr("添加")) { addKeyword() }
                        .controlSize(.small)
                        .disabled(s.current == nil || newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Divider()
            Text(s.current?.url.path ?? "—").font(.system(size:11)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            Button(L10n.tr("在访达中显示")) { if let url = s.current?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.disabled(s.current == nil)
            if let error = s.workflowError { Label(error,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(WorkspaceTokens.error).fixedSize(horizontal:false,vertical:true) }
        }.padding(16).frame(width:330).workspaceGlassPanel()
            .task(id:s.current?.url) { metadata = WorkspacePhotoMetadata.read(s.current?.url) }
    }
    private func addKeyword() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        s.setKeywords(s.currentKeywords + [trimmed])
        newKeyword = ""
    }
    private func information(_ name:String,value:String) -> some View {
        HStack(alignment:.firstTextBaseline) { Text(L10n.tr(name)).foregroundStyle(WorkspaceTokens.secondaryText); Spacer(); Text(value).textSelection(.enabled) }.font(.system(size:12))
    }
}

enum WorkspacePhotoMetadata {
    static func read(_ url:URL?) -> [String:String] {
        guard let url, let src = CGImageSourceCreateWithURL(url as CFURL,nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [String:Any] else { return [:] }
        let exif = p[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String:Any] ?? [:]
        var result:[String:String] = [:]
        result["相机"] = tiff[kCGImagePropertyTIFFModel as String] as? String
        result["镜头"] = exif[kCGImagePropertyExifLensModel as String] as? String
        result["拍摄时间"] = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let first = iso.first { result["ISO"] = first.stringValue }
        if let f = exif[kCGImagePropertyExifFNumber as String] as? NSNumber { result["光圈"] = "ƒ/"+f.stringValue }
        if let t = exif[kCGImagePropertyExifExposureTime as String] as? Double, t > 0 { result["快门"] = t < 1 ? "1/\(Int((1/t).rounded())) s" : String(format:"%.2f s",t) }
        return result
    }
}
