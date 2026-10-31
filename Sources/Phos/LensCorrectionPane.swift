import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LensCorrectionPane: View {
    @EnvironmentObject var s:AppState
    @ObservedObject private var language=AppLanguage.shared
    @State private var manage=false
    private func update(_ change:(inout LensCorrection)->Void) {
        guard var c=s.params.lensCorrection else { return }; s.lensCompare=false; s.parameterEdits.finishCurrent(); change(&c)
        var p=s.params; p.lensCorrection=c; s.commit(p)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Button(L10n.tr("镜头配置与导入…")) { s.parameterEdits.finishCurrent(); manage=true }.controlSize(.small)
                .sheet(isPresented:$manage) { LensProfileSheet().environmentObject(s).environment(\.locale,language.locale) }
            if let c=s.params.lensCorrection {
                Text(c.name).font(.caption.weight(.medium)).fixedSize(horizontal:false,vertical:true)
                Label(L10n.tr(c.selectionMethod == "auto" ? "自动匹配 · 已确认" : c.selectionMethod == "manual" ? "手动选择 · 已确认" : "已保存配置 · 请核对"),systemImage:"checkmark.circle").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle(L10n.tr("校正前后"),isOn:$s.lensCompare).toggleStyle(.button).disabled(!c.enabled || s.source == nil)
                    Toggle(isOn:$s.lensGrid) { Label(L10n.tr("网格"),systemImage:"grid") }.toggleStyle(.button)
                }.buttonStyle(WorkspaceButtonStyle()).controlSize(.small)
                Text(L10n.tr("对比仅暂时关闭镜头配置；其他调整保留。再次点击返回。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if c.distortion == nil { missing("暂无畸变标定数据") }
                if c.tca == nil { missing("暂无横向色差标定数据") }
                if c.vignetting == nil { missing("暂无暗角标定数据") }
                Toggle(L10n.tr("启用配置校正"),isOn:Binding(get:{c.enabled},set:{v in update{$0.enabled=v}}))
                Toggle(L10n.tr("畸变校正"),isOn:Binding(get:{c.correctDistortion},set:{v in update{$0.correctDistortion=v}})).disabled(c.distortion == nil)
                Toggle(L10n.tr("横向色差校正"),isOn:Binding(get:{c.correctTCA},set:{v in update{$0.correctTCA=v}})).disabled(c.tca == nil)
                Toggle(L10n.tr("暗角补偿（最接近采样）"),isOn:Binding(get:{c.correctVignetting},set:{v in update{$0.correctVignetting=v}})).disabled(c.vignetting == nil)
                Toggle(L10n.tr("自动裁边"),isOn:Binding(get:{c.autoCrop},set:{v in update{$0.autoCrop=v}}))
                Button(L10n.tr("移除镜头配置")) { s.lensCompare=false; s.lensGrid=false; s.parameterEdits.finishCurrent(); var p=s.params; p.lensCorrection=nil; s.commit(p) }.controlSize(.small)
            } else {
                Text(L10n.tr("选择或导入配置，校正畸变、暗角和色差。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            if let ext=s.current?.url.pathExtension.lowercased(), ["jpg","jpeg","heic","heif","hif"].contains(ext) {
                Label(L10n.tr("此类照片可能已由相机校正，请对比确认，避免重复校正。"),systemImage:"info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Divider()
        }.font(.system(size:11)).disabled(s.cropMode)
            .onDisappear { s.lensCompare=false; s.lensGrid=false }
    }
    private func missing(_ title:String)->some View {
        Label(L10n.tr(title),systemImage:"minus.circle").font(.caption).foregroundStyle(.secondary)
    }
}

struct LensProfileSheet:View {
    @EnvironmentObject var s:AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store=LensProfileStore.shared
    @ObservedObject private var language=AppLanguage.shared
    @State private var selected=""
    @State private var query=""
    @State private var message=""
    @State private var guide=false
    @State private var focal=50.0
    @State private var aperture=5.6
    @State private var distance=10.0
    @State private var crop=1.0
    @State private var confirmed=false
    @State private var selectionMethod="manual"
    private var profile:LensProfile? { store.profiles.first{$0.id==selected} }
    private var resolved:LensCorrection? { profile?.resolve(focal:focal,aperture:aperture,distance:distance,cameraCrop:crop) }
    private var matches:[LensProfile] { store.profiles.filter{query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)} }
    private var metadata:LensPhotoMetadata { LensPhotoMetadata(url:s.current?.url) }
    private func autoMatch() {
        let data=metadata
        if data.focal>0 { focal=data.focal }; if data.aperture>0 { aperture=data.aperture }
        if let known=store.cameras[data.camera] { crop=known }
        let candidates=store.matches(data.lens).filter{crop >= $0.crop*0.98}
        if candidates.count==1 { selectionMethod="auto"; selected=candidates[0].id; query=""; message=L10n.tr("已找到同名镜头，请核对焦距、光圈及机身裁切系数。") }
        else { selected=""; message=L10n.tr("无法唯一匹配，请搜索并手动选择镜头。") }
        confirmed=false
    }
    private func importProfile() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.xml]; panel.allowsMultipleSelection=false
        panel.message=L10n.tr("导入 Lensfun XML 镜头配置（不支持直接导入 LCP）")
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { let count=try store.importFile(url); message=L10n.tr("已导入 \(count) 款可用镜头。"); query="" }
        catch { message=error.localizedDescription }
    }
    private func restoreOrMatch() {
        guard let c=s.params.lensCorrection else { autoMatch(); return }
        selectionMethod=c.selectionMethod ?? "saved"
        selected=c.profileID ?? store.profiles.first(where:{$0.title==c.name && $0.crop == (c.distortion?.crop ?? c.tca?.crop ?? c.vignetting?.crop)})?.id ?? ""
        focal=c.captureFocal ?? c.distortion?.focal ?? c.tca?.focal ?? 50
        aperture=c.captureAperture ?? 5.6; distance=c.captureDistance ?? 10; crop=c.cameraCrop
        confirmed=false; message=""
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(L10n.tr("镜头配置校正")).font(.title2.bold()); Spacer(); Button(L10n.tr("导入指引")){guide=true}; Button(L10n.tr("完成")){dismiss()} }
            Text(metadata.lens.isEmpty ? L10n.tr("照片未提供镜头名称，可手动选择。") : metadata.lens).font(.caption).foregroundStyle(.secondary)
            HStack { Button(L10n.tr("自动匹配")){autoMatch()}; Button(L10n.tr("导入 XML…")){importProfile()}; Spacer(); Text(L10n.tr("可用镜头：\(store.profiles.count)")).font(.caption) }
            TextField(L10n.tr("搜索镜头（例如 EF 24-105）"),text:$query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:2) {
                    ForEach(matches) { p in
                        Button { selected=p.id; selectionMethod="manual"; confirmed=false; message="" } label: {
                            HStack { Image(systemName:selected==p.id ? "checkmark.circle.fill":"circle"); Text(p.title).lineLimit(2); Spacer(); Text(String(format:"×%.2f",p.crop)).foregroundStyle(.secondary) }
                                .padding(7).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(p.title)
                    }
                    if matches.isEmpty { Text(L10n.tr("没有匹配的镜头，请导入配置。")) }
                }
            }.frame(height:170).background(.quaternary.opacity(0.25),in:RoundedRectangle(cornerRadius:8))
            Grid(alignment:.leading,horizontalSpacing:12,verticalSpacing:7) {
                GridRow { Text(L10n.tr("焦距（mm）")); TextField("",value:$focal,format:.number).accessibilityLabel(L10n.tr("焦距（mm）")); Text(L10n.tr("光圈（f）")); TextField("",value:$aperture,format:.number).accessibilityLabel(L10n.tr("光圈（f）")) }
                GridRow { Text(L10n.tr("机身裁切系数")); TextField("",value:$crop,format:.number).accessibilityLabel(L10n.tr("机身裁切系数")); Text(L10n.tr("对焦距离（m）")); TextField("",value:$distance,format:.number).accessibilityLabel(L10n.tr("对焦距离（m）")) }
            }.textFieldStyle(.roundedBorder)
            Text(L10n.tr("全画幅填 1；Canon APS-C 通常为 1.6。请核对机身；增距镜、减焦镜和已裁切图片不自动推断。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let c=resolved {
                HStack { capability("畸变校正",c.distortion != nil); capability("横向色差校正",c.tca != nil); capability("暗角补偿",c.vignetting != nil) }.font(.caption)
                if let v=c.vignetting { Text(L10n.tr("暗角采用最接近的实测采样：\(String(format:"%.1f",v.focal)) mm · f/\(String(format:"%.1f",v.aperture)) · \(String(format:"%.1f",v.distance)) m")).font(.caption).foregroundStyle(.secondary) }
            } else { Text(L10n.tr("请选择适用配置；焦距须在标定范围内，机身传感器不可大于标定传感器。" )).font(.caption).foregroundStyle(.secondary) }
            if !message.isEmpty { Text(message).font(.caption).fixedSize(horizontal:false,vertical:true).accessibilityLabel(message) }
            Toggle(L10n.tr("已核对镜头与拍摄参数，确认照片未重复应用同类校正。"),isOn:$confirmed).font(.caption)
            HStack { Text(L10n.tr("应用后可撤销；暗角补偿默认关闭。" )).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L10n.tr("应用到当前照片")) {
                guard var c=resolved,confirmed else { return }; c.selectionMethod=selectionMethod; s.lensCompare=false; s.parameterEdits.finishCurrent(); var p=s.params; p.lensCorrection=c; s.commit(p); dismiss()
            }.buttonStyle(.borderedProminent).disabled(resolved==nil || !confirmed || s.source==nil || s.syncRunning || s.cropMode) }
        }.padding(20).frame(width:620).onAppear{restoreOrMatch()}
            .sheet(isPresented:$guide){ LensImportGuide() }
    }
    private func capability(_ title:String,_ enabled:Bool)->some View { Label(L10n.tr(title),systemImage:enabled ? "checkmark.circle":"minus.circle").foregroundStyle(enabled ? Color.primary:Color.secondary) }
}

struct LensImportGuide:View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language=AppLanguage.shared
    static let steps=[
        "适马 16–300：内置 16–300mm F3.5–6.7 DC OS Contemporary 025 的畸变及横向色差数据，不含暗角数据。标定来自 Fujifilm X-S20，裁切系数 1.534；使用其他机身时请填写实际机身裁切系数，并检查实拍效果。",
        "1. 获取配置：仅内置 5 款精选镜头配置，包含适马 16–300 和常用 EF 老镜头。其他镜头可从 Lensfun 官方数据库下载对应 XML；请保存原始文件，不要保存网页。",
        "2. 导入：选择“镜头配置与导入…”→“导入 XML…”。只接受不超过 8 MB 的 Lensfun lensdatabase v1/v2 XML；不会修改源文件。有效配置会复制到本机配置库。",
        "3. 核对匹配：自动匹配只接受唯一同名结果。转接或缺少 EXIF 时，手动选择镜头，填写焦距、光圈、机身裁切系数和对焦距离。不要把标定裁切系数当成机身裁切系数。",
        "4. 应用：核对后应用到当前照片，再分别启用畸变、色差和暗角补偿。暗角采用最接近实测采样，默认关闭，最大增益限制为 4 倍，避免过度放大噪点。",
        "5. 检查：使用原图对比观察直线、边缘和四角。自动裁边通过缩放保留输出尺寸；关闭后可能出现透明边缘。配置及所用系数会写入编辑旁档，导出和预览共用校正。",
        "支持范围：直线镜头；畸变 poly3 / poly5 / ptlens，色差 linear / poly3，暗角 pa。不支持鱼眼、ACM、偏心中心、LCP 和压缩包；不支持的数据不会启用。部分镜头只提供一两项校正。",
        "避免重复校正：JPEG/HEIF、手机照片及部分 RAW 解码可能已做镜头校正。只在确认未做相同校正时启用；增距镜、减焦镜、移轴或预裁切图片需专用标定。",
        "配置位置：~/Library/Application Support/Phos/LensProfiles。导入配置长期保留；已有编辑保存系数快照，删除配置文件也不会改变已保存编辑。"
    ]
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack{Text(L10n.tr("镜头配置导入指引")).font(.title2.bold()); Spacer(); Button(L10n.tr("完成")){dismiss()} }
            ScrollView{VStack(alignment:.leading,spacing:14){ForEach(Self.steps,id:\.self){Text(L10n.tr($0)).fixedSize(horizontal:false,vertical:true)}}}.frame(height:430)
            Link(L10n.tr("打开 Lensfun 官方配置库"),destination:URL(string:"https://github.com/lensfun/lensfun/tree/master/data/db")!)
            Text("Lensfun database © Lensfun contributors · CC BY-SA 3.0").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width:600)
    }
}
