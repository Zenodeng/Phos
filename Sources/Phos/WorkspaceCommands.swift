import SwiftUI

struct WorkspaceMenuCommands: Commands {
    @ObservedObject var state: AppState
    @ObservedObject var history: History
    @FocusedValue(\.workspaceCommands) private var model
    private var ready: Bool { model != nil && state.source != nil && !state.syncRunning }
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { model?.undo() }.keyboardShortcut("z").disabled(!ready || (!history.canUndo && state.pendingPhotoEditID == nil))
            Button("重做") { model?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!ready || !history.canRedo)
        }
        CommandGroup(after: .newItem) {
            Button("打开文件夹…") { model?.openFolder() }.keyboardShortcut("o").disabled(model == nil || state.syncRunning)
            Button("导出当前照片…") { model?.present(.export) }.keyboardShortcut("e").disabled(!ready || state.exportRunning)
            Button("裁剪") { model?.finishEditing(); state.toggleCropMode() }.keyboardShortcut("r").disabled(!ready)
            Button("批量导出…") { model?.present(.batch) }.disabled(!ready)
            Button("多重曝光合成…") { model?.present(.merge) }.keyboardShortcut("m", modifiers: [.command, .shift]).disabled(!ready)
            Button("前后对比") { state.showBefore.toggle() }.keyboardShortcut("b").disabled(!ready)
            Button("复制调整") { model?.finishEditing(); state.copyAdjustments() }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!ready)
            Button("同步调整…") { model?.present(.sync) }.keyboardShortcut("v", modifiers: [.command, .shift]).disabled(!ready)
            Button("命名快照…") { model?.present(.snapshots) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!ready)
        }
        CommandGroup(after: .toolbar) {
            Button("A · 沉浸编辑") { model?.session.mode = .immersive }
                .keyboardShortcut("a", modifiers: [.command, .control]).disabled(model == nil)
            Button("B · 连续选片") { model?.session.mode = .filmstrip }
                .keyboardShortcut("b", modifiers: [.command, .control]).disabled(model == nil)
            Button("显示或隐藏照片浏览器") { model?.session.browserVisible.toggle() }
                .keyboardShortcut("1", modifiers: [.command, .option]).disabled(model == nil)
            Button("显示或隐藏调整面板") { model?.session.inspectorVisible.toggle() }
                .keyboardShortcut("2", modifiers: [.command, .option]).disabled(model == nil)
            Button("适合窗口") { model?.fit() }.keyboardShortcut("0").disabled(!ready)
            Button("1:1 检查") { state.oneToOne.toggle() }.keyboardShortcut("1").disabled(!ready || state.cropMode)
        }
    }
}
