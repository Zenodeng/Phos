import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceExportValidation {
    static func error(_ p: ExportSettings, edge: String, cutout: Bool = false) -> String? {
        guard ["jpg","png","tiff","heic"].contains(p.format) else { return "请选择支持的输出格式" }
        guard let n = Int(edge), (0...100000).contains(n) else { return "长边请输入 0 至 100000 的整数，0 表示原尺寸" }
        guard p.quality.isFinite, (0.3...1).contains(p.quality) else { return "质量应在 0.3 至 1 之间" }
        guard [8,16].contains(p.tiffBitDepth) else { return "TIFF 位深应为 8 或 16 位" }
        if cutout && !["png","tiff"].contains(p.format) { return "透明背景请使用 PNG 或 TIFF" }
        if p.watermarkEnabled {
            guard [p.watermarkScale,p.watermarkOpacity,p.watermarkRotation,p.watermarkMargin].allSatisfy(\.isFinite),
                  (0.01...0.3).contains(p.watermarkScale), (0.05...1).contains(p.watermarkOpacity),
                  (-45...45).contains(p.watermarkRotation), (0...0.12).contains(p.watermarkMargin) else { return "请检查水印大小、不透明度、旋转和边距" }
            guard ExportSettings.wmPositions.contains(p.watermarkPosition) else { return "请选择水印位置" }
            if p.watermarkKind == "text" {
                if p.watermarkText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return "请输入水印文字" }
            } else if p.watermarkKind == "image" {
                guard NSImage(contentsOfFile:p.watermarkImagePath) != nil else { return "请选择可读取的水印图片" }
            } else { return "请选择水印类型" }
        }
        return nil
    }
}

struct WorkspaceFormSection<Content:View>: View {
    let title:String
    @ViewBuilder var content:Content
    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            Text(title).font(.system(size:12,weight:.semibold))
            content
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            .background(WorkspaceTokens.readoutColor.opacity(0.7),in:RoundedRectangle(cornerRadius:10))
    }
}

struct ExportSheet: View {
    var body: some View { WorkspaceOutputSheet(batch:false) }
}
struct BatchSheet: View {
    var body: some View { WorkspaceOutputSheet(batch:true) }
}

private struct WorkspaceOutputSheet: View {
    let batch:Bool
    @EnvironmentObject private var s:AppState
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ExportSettings()
    @State private var edge = "0"
    @State private var directory = ExportPaths.defaultDir
    @State private var onlyPicked = false
    @State private var cutout = false
    @State private var capturedPhoto:UUID?
    private var validation:String? { WorkspaceExportValidation.error(settings,edge:edge,cutout:cutout) }
    private var targetCount:Int { s.items.filter { !onlyPicked || $0.picked }.count }
    private var disabled:Bool { validation != nil || (batch ? s.batchRunning || targetCount == 0 : s.source == nil || s.exportRunning || capturedPhoto != s.current?.id) }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:9) {
                Image(systemName:batch ? "tray.and.arrow.down" : "square.and.arrow.up").foregroundStyle(WorkspaceTokens.accent)
                Text(batch ? "批量导出" : "导出当前照片").font(.system(size:17,weight:.semibold))
            }
            Text(batch ? "使用各张照片已保存的调整" : s.current?.url.lastPathComponent ?? "未选择照片").font(.system(size:12)).foregroundStyle(WorkspaceTokens.secondaryText).lineLimit(1)
            ScrollView {
                VStack(spacing:10) {
                    WorkspaceFormSection(title:"文件与格式") {
                        HStack {
                            Image(systemName:"folder")
                            Text(directory.path).font(.system(size:11)).lineLimit(2).truncationMode(.middle).help(directory.path)
                            Spacer(); Button("更改…") { chooseDirectory() }
                        }
                        Picker("格式",selection:$settings.format) {
                            if !cutout { Text("JPEG").tag("jpg") }
                            Text("PNG").tag("png"); Text("TIFF").tag("tiff")
                            if !cutout { Text("HEIC").tag("heic") }
                        }.pickerStyle(.segmented)
                        OutputPrecisionControls(settings:$settings)
                    }
                    WorkspaceFormSection(title:"尺寸与质量") {
                        HStack {
                            Text("长边"); Spacer()
                            TextField("0",text:$edge).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width:92).accessibilityLabel("输出长边")
                            Text("px").foregroundStyle(WorkspaceTokens.secondaryText)
                        }.font(.system(size:12))
                        Text("0 保留原尺寸").font(.caption).foregroundStyle(WorkspaceTokens.secondaryText)
                        SliderRow(label:"质量",value:$settings.quality,range:0.3...1,defaultValue:0.95,decimals:2,photoScoped:false)
                            .disabled(settings.format == "tiff" || settings.format == "png")
                        Toggle("输出锐化",isOn:$settings.sharpenForOutput)
                        if batch { Toggle("只导出已标记照片（\(targetCount) 张）",isOn:$onlyPicked) }
                        else {
                            Toggle("透明背景抠图",isOn:$cutout)
                                .disabled(!s.params.masks.contains { $0.kind == .foreground && $0.enabled })
                        }
                    }
                    WorkspaceFormSection(title:"水印") {
                        Toggle("添加水印",isOn:$settings.watermarkEnabled)
                        if settings.watermarkEnabled { WatermarkControls(settings:$settings) }
                    }
                    if let validation { Label(validation,systemImage:"exclamationmark.circle").font(.system(size:12)).foregroundStyle(WorkspaceTokens.error).fixedSize(horizontal:false,vertical:true) }
                }.padding(1)
            }.frame(maxHeight:475)
            Divider()
            HStack {
                Button("取消",role:.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(batch ? "导出 \(targetCount) 张" : "导出…") { confirm() }
                    .buttonStyle(WorkspaceButtonStyle(prominent:true)).keyboardShortcut(.defaultAction).disabled(disabled)
            }
        }.padding(20).frame(width:440).workspaceGlassPanel()
            .onAppear { settings = s.exportSettings; edge = String(settings.maxLongEdge); capturedPhoto = s.current?.id }
            .onChange(of:cutout) { _, on in if on && !["png","tiff"].contains(settings.format) { settings.format = "png" } }
    }
    private func chooseDirectory() {
        let p = WorkspaceWindowModel.makeFolderPanel(directory:directory)
        if p.runModal() == .OK, let url = p.url { directory = url }
    }
    private func confirm() {
        guard !disabled, let n = Int(edge) else { return }
        var committed = settings; committed.maxLongEdge = n
        if batch {
            s.exportSettings = committed
            UserDefaults.standard.set(directory.path,forKey:ExportPaths.key)
            let destination = directory, picked = onlyPicked
            s.startBatchExport(to:destination,onlyPicked:picked)
            dismiss()
        } else {
            let p = NSSavePanel(); p.directoryURL = directory
            p.nameFieldStringValue = (s.current?.url.deletingPathExtension().lastPathComponent ?? "out")+"."+committed.format
            if p.runModal() == .OK, let url = p.url {
                guard capturedPhoto == s.current?.id else { return }
                s.exportSettings = committed
                UserDefaults.standard.set(directory.path,forKey:ExportPaths.key)
                if cutout { s.exportCutout(to:url) } else { s.exportCurrent(to:url) }
                dismiss()
            }
        }
    }
}
