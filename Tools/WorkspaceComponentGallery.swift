import SwiftUI
import AppKit

struct WorkspaceComponentGallery: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var zero = 0.0
    @State private var negative = -24.0
    @State private var endpoint = 100.0
    @State private var longValue = 3.25
    @State private var selected = true
    @State private var sampleError: String?
    @State private var inputStatus = "准备就绪"

    private func row(_ title:String, _ value:Binding<Double>, decimals:Int = 0) -> some View {
        WorkspaceParameterRow(label:title,value:value,decimals:decimals,onCommit:{inputStatus = "数值已确认"})
    }
    private func section<Content:View>(_ title:String,@ViewBuilder content:() -> Content) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Text(title).font(.system(size:15,weight:.semibold))
            content()
            Spacer(minLength:0)
        }.padding(16).frame(maxWidth:.infinity,alignment:.topLeading)
            .background(RoundedRectangle(cornerRadius:14).fill(WorkspaceTokens.chartColor))
            .overlay(RoundedRectangle(cornerRadius:14).stroke(WorkspaceTokens.hairline,lineWidth:0.5))
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("组件样板").font(.system(size:20,weight:.semibold))
                    Text("Tab 移动焦点 · 空格按下按钮 · Enter 确认 · Esc 取消输入").font(.system(size:11)).foregroundStyle(WorkspaceTokens.secondaryText)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                HStack(alignment:.top,spacing:16) {
                    section("按钮与数值") {
                        HStack(spacing:4) {
                            WorkspaceIconButton(symbol:"sidebar.left",title:"选中状态",selected:selected) { selected.toggle() }
                            WorkspaceIconButton(symbol:"arrow.uturn.backward",title:"默认按钮") { inputStatus = "按钮已按下" }
                            WorkspaceIconButton(symbol:"arrow.uturn.forward",title:"禁用按钮",disabled:true) {}
                        }
                        HStack(spacing:8) {
                            Button {} label: { Image(systemName:"arrow.uturn.backward").symbolRenderingMode(.hierarchical).font(.system(size:14,weight:.medium)).frame(width:24,height:24) }
                                .buttonStyle(WorkspaceButtonStyle(previewPressed:true)).accessibilityLabel("按压样本")
                            Text("按压样本").font(.system(size:11)).foregroundStyle(WorkspaceTokens.secondaryText)
                        }
                        Divider()
                        row("零值",$zero)
                        row("负值",$negative)
                        row("量程端点",$endpoint)
                        row("局部调整强度的长标签检查",$longValue,decimals:2)
                        Text(inputStatus).font(.system(size:11)).foregroundStyle(WorkspaceTokens.secondaryText)
                    }
                    section("分组与图表") {
                        WorkspaceAdjustmentGroup(title:"可展开分组",modified:negative != 0,reset:{negative = 0}) {
                            row("修改值",$negative)
                        }
                        WorkspaceAdjustmentGroup(title:"收起状态",expanded:false,reset:{}) { Text("展开后内容") }
                        VisualLabHistogram(state:state)
                        Text("色调曲线").font(.system(size:12,weight:.medium))
                        CurveEditor(points:Binding(get:{state.params.curve.points},set:{state.set(\.curve,ToneCurve(points:$0))}),color:WorkspaceTokens.accent) { state.endEdit() }
                            .frame(height:170)
                        Text("中间调色轮").font(.system(size:12,weight:.medium))
                        GradeWheel(grade:Binding(get:{state.params.gradeMid},set:{state.set(\.gradeMid,$0)})) { state.endEdit() }
                            .frame(width:136,height:136)
                    }
                    section("照片与工作流状态") {
                        if let item = state.current {
                            Text(item.url.lastPathComponent).font(.system(size:12,weight:.medium)).lineLimit(2)
                            HStack(spacing:4) {
                                ForEach(1...5,id:\.self) { rating in
                                    Button { state.setRating(rating == item.rating ? 0 : rating) } label: {
                                        Image(systemName:rating <= item.rating ? "star.fill" : "star").symbolRenderingMode(.hierarchical)
                                    }.buttonStyle(.plain).foregroundStyle(WorkspaceTokens.accent).frame(width:28,height:32)
                                        .accessibilityLabel("样板评分\(rating)星")
                                }
                            }
                            Button { state.togglePick() } label: { Label(item.picked ? "已标记" : "标记照片",systemImage:item.picked ? "flag.fill" : "flag") }
                            Toggle("加入多选",isOn:Binding(get:{state.selectedPhotos.contains(item.id)},set:{if $0 { state.selectedPhotos.insert(item.id) } else { state.selectedPhotos.remove(item.id) }}))
                        }
                        Divider()
                        if state.previewing { ProgressView().controlSize(.small); Text("正在生成预览…") }
                        else { Label("预览就绪",systemImage:"checkmark.circle").foregroundStyle(WorkspaceTokens.success) }
                        Button("导出表单") { state.showExport = true }
                        Button("同步表单") { state.showSync = true }
                        Button("快照表单") { state.showSnapshots = true }
                        Divider()
                        if let error = sampleError {
                            Label(error,systemImage:"exclamationmark.triangle").font(.system(size:12)).foregroundStyle(WorkspaceTokens.error)
                            Button("重试有效样本") { if let url = state.current?.url,Engine.decode(url) != nil { sampleError = nil } }
                        } else {
                            Button("加载错误样本") {
                                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Phos-component-error-"+UUID().uuidString+".jpg")
                                do {
                                    try Data("corrupt image fixture".utf8).write(to:url)
                                    if Engine.decode(url) == nil { sampleError = "此样本无法解码，可重新加载有效照片。" }
                                } catch { sampleError = error.localizedDescription }
                            }
                        }
                    }
                }.padding(.bottom,4)
            }
        }.padding(20).frame(width:920,height:700)
            .foregroundStyle(WorkspaceTokens.primaryText).tint(WorkspaceTokens.accent)
            .sheet(isPresented:$state.showExport) { ExportSheet().environmentObject(state) }
            .sheet(isPresented:$state.showSync) { SyncSheet().environmentObject(state) }
            .sheet(isPresented:$state.showSnapshots) { SnapshotSheet().environmentObject(state) }
    }
}
