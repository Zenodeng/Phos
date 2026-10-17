import SwiftUI
import ImageIO
import CoreImage

struct WorkspaceInspector: View {
    @ObservedObject var state: AppState
    @ObservedObject private var ui: WorkspaceInspectorState
    @State private var confirmReset = false
    init(state: AppState) { self.state = state; ui = state.inspectorUI }
    var body: some View {
        VStack(spacing:0) {
            VStack(spacing:5) {
                HStack {
                    Text(state.showBefore ? "原图" : state.cropMode ? "裁剪参考" : "调整后")
                    Spacer()
                    if state.previewing { ProgressView().controlSize(.mini) }
                    Text("RGB").monospaced()
                }.font(.system(size:10,weight:.medium)).foregroundStyle(WorkspaceTokens.secondaryText)
                HistogramView(bins:state.hist).frame(height:46)
                    .accessibilityLabel("当前照片 RGB 直方图")
            }.padding(.horizontal,12).padding(.top,12).padding(.bottom,10)
            HStack(spacing:4) {
                Button { state.parameterEdits.finishCurrent(); state.showPhotoAI = true } label: {
                    Label("AI 修图",systemImage:"sparkles").font(.system(size:11))
                }.buttonStyle(WorkspaceButtonStyle()).disabled(state.source == nil).help("用本地模型调整照片")
                Text("调整").font(.system(size:13,weight:.semibold))
                Spacer()
                Button { state.parameterEdits.invalidate(); confirmReset = true } label: {
                    Image(systemName:"arrow.counterclockwise").font(.system(size:12)).frame(width:18,height:18)
                }.buttonStyle(WorkspaceButtonStyle()).disabled(state.source == nil).help("恢复所有默认参数").accessibilityLabel("恢复所有默认参数")
                Button { state.parameterEdits.finishCurrent(); ui.showPresets.toggle() } label: {
                    Label("预设",systemImage:"square.grid.2x2").font(.system(size:11))
                }.buttonStyle(WorkspaceButtonStyle(selected:ui.showPresets)).help("浏览预设")
                    .popover(isPresented:$ui.showPresets,arrowEdge:.leading) {
                        WorkspacePresetBrowser().environmentObject(state)
                    }
                Button { ui.showInformation.toggle() } label: {
                    Image(systemName:"info.circle").font(.system(size:13)).frame(width:18,height:18)
                }.buttonStyle(WorkspaceButtonStyle(selected:ui.showInformation)).help("照片信息").accessibilityLabel("照片信息")
                    .popover(isPresented:$ui.showInformation,arrowEdge:.leading) {
                        WorkspacePhotoInformation().environmentObject(state)
                    }
            }.padding(.horizontal,10).frame(height:36)
            Divider()
            InspectorPane(transparent:true,ui:ui).disabled(state.source == nil)
        }.environmentObject(ui)
            .alert("恢复所有默认参数？",isPresented:$confirmReset) {
                Button("取消",role:.cancel) {}
                Button("恢复默认",role:.destructive) { state.selectedMask = nil; state.commit(EditParams()) }
            } message: { Text("此操作可撤销，原始照片不会改变。") }
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
        return presets.filter { (collection == .all || ($0.builtin ? collection == .builtin : collection == .personal)) && (q.isEmpty || $0.name.localizedStandardContains(q)) }
    }
}

struct WorkspacePresetBrowser: View {
    @EnvironmentObject private var s: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = PresetPreviewModel()
    @State private var query = ""
    @State private var name = ""
    @State private var catalogError: String?
    @State private var collection: PresetCollection = .all
    @State private var presets: [Preset] = []
    @State private var selection: UUID?
    private var selected: Preset? { presets.first { $0.id == selection } }
    private var shown: [Preset] { WorkspacePresetPolicy.filtered(presets,query:query,collection:collection) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("预设").font(.system(size:16,weight:.semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            Picker("集合",selection:$collection) { ForEach(PresetCollection.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            TextField("搜索预设",text:$query).textFieldStyle(.roundedBorder)
            if let catalogError { Label(catalogError,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(WorkspaceTokens.error).fixedSize(horizontal:false,vertical:true) }
            HStack(alignment:.top,spacing:12) {
                ScrollView {
                    LazyVStack(spacing:3) {
                        ForEach(shown) { preset in
                            Button { selection = preset.id; refreshPreview() } label: {
                                HStack(spacing:7) {
                                    Image(systemName:preset.builtin ? "sparkles" : "person.crop.square").frame(width:16)
                                    Text(preset.name).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                                    if selection == preset.id { Image(systemName:"checkmark").font(.caption) }
                                }.font(.system(size:12)).padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .background(selection == preset.id ? WorkspaceTokens.accent.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:6))
                                .accessibilityAddTraits(selection == preset.id ? .isSelected : [])
                        }
                        if shown.isEmpty { Text("没有匹配的预设").font(.caption).foregroundStyle(WorkspaceTokens.secondaryText).padding(.vertical,30) }
                    }
                }.frame(width:154,height:200)
                VStack(spacing:8) {
                    ZStack {
                        RoundedRectangle(cornerRadius:8).fill(WorkspaceTokens.chartColor)
                        if let image = preview.image { Image(decorative:image,scale:1).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius:8)) }
                        else if preview.busy { ProgressView() }
                        else { Text(preview.failed ? "无法生成预览" : "选择预设以预览").font(.caption).foregroundStyle(WorkspaceTokens.secondaryText) }
                    }.frame(width:228,height:170)
                    Text(selected?.name ?? "当前照片预览").font(.caption).foregroundStyle(WorkspaceTokens.secondaryText).lineLimit(1)
                }
            }
            HStack {
                TextField("保存当前调整为新预设",text:$name).textFieldStyle(.roundedBorder)
                Button("保存") {
                    let preset = Preset(name:String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(120)),params:s.params)
                    if s.savePresets(presets+[preset]) { presets.append(preset); name = ""; catalogError = nil }
                }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || s.source == nil || catalogError != nil)
            }
            HStack { Text("预览不会改动照片").font(.caption).foregroundStyle(WorkspaceTokens.secondaryText); Spacer()
                Button("取消",role:.cancel) { dismiss() }
                Button("应用预设") { if let selected { s.commit(selected.params); dismiss() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selected == nil || s.source == nil || s.syncRunning)
            }
        }.padding(16).frame(width:438).background(Color(nsColor:WorkspaceTokens.panel))
            .onAppear { load() }
            .onChange(of:s.current?.id) { _, _ in refreshPreview() }
    }
    private func load() {
        let catalog = WorkspacePresetCatalog.load(s.presetsURL,fallback:s.loadPresets())
        presets = catalog.presets; catalogError = catalog.error
    }
    private func refreshPreview() { preview.show(selected,source:s.source,photoID:s.current?.id) }
}

struct WorkspacePhotoInformation: View {
    @EnvironmentObject private var s: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var metadata: [String:String] = [:]
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("照片信息").font(.system(size:16,weight:.semibold)); Spacer(); Button("完成") { dismiss() } }
            Text(s.current?.url.lastPathComponent ?? "未选择照片").font(.system(size:13,weight:.medium)).textSelection(.enabled)
            information("原图尺寸",value:s.sourceSize.width > 0 ? "\(Int(s.sourceSize.width)) × \(Int(s.sourceSize.height))" : "—")
            information("当前输出",value:s.displayFrame.map { "\(Int($0.editedExtent.width)) × \(Int($0.editedExtent.height))" } ?? "—")
            information("预览",value:s.displayFrame.map { "\($0.image.width) × \($0.image.height) · \($0.fullResolution ? "完整" : "代理")" } ?? "—")
            ForEach(["相机","镜头","ISO","快门","光圈","拍摄时间"],id:\.self) { key in information(key,value:metadata[key] ?? "—") }
            Divider()
            Text(s.current?.url.path ?? "—").font(.system(size:11)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            Button("在访达中显示") { if let url = s.current?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.disabled(s.current == nil)
            if let error = s.workflowError { Label(error,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(WorkspaceTokens.error).fixedSize(horizontal:false,vertical:true) }
        }.padding(16).frame(width:330).background(Color(nsColor:WorkspaceTokens.panel))
            .task(id:s.current?.url) { metadata = WorkspacePhotoMetadata.read(s.current?.url) }
    }
    private func information(_ name:String,value:String) -> some View {
        HStack(alignment:.firstTextBaseline) { Text(name).foregroundStyle(WorkspaceTokens.secondaryText); Spacer(); Text(value).textSelection(.enabled) }.font(.system(size:12))
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
