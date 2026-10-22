import SwiftUI
import AppKit

enum WorkspaceCommandID: String, CaseIterable {
    case undo, redo, openFolder, export, batch, merge, crop, beforeOriginal, beforeGeometry
    case copy, sync, snapshots, fit, pixel100, masks, brush, overlay, whiteBalance, autoTone, cancelJob
}
@MainActor extension WorkspaceWindowModel {
    func enabled(_ command:WorkspaceCommandID) -> Bool {
        let s = state, ready = s.source != nil && !s.syncRunning
        switch command {
        case .cancelJob: return s.jobRunning && s.jobCancellation?.cancelled != true
        case .openFolder: return !s.syncRunning && folderPanel == nil && router.presented == nil
        case .undo: return ready && (s.history.canUndo || s.pendingPhotoEditID != nil || s.cropSession != nil)
        case .redo: return ready && s.history.canRedo && s.cropSession == nil
        case .export,.batch: return ready && !s.jobRunning && s.cropSession == nil
        case .sync: return ready && !s.jobRunning && !s.selectedPhotos.isEmpty && s.cropSession == nil
        case .merge: return ready && !s.mergeRunning && s.cropSession == nil
        case .pixel100,.beforeOriginal,.beforeGeometry: return ready && !s.cropMode
        case .whiteBalance: return ready && !s.cropMode && !s.previewing && !s.whiteBalanceRunning
        case .autoTone: return ready && !s.autoRunning && !s.previewing && !s.cropMode
        case .overlay: return ready && s.selectedMask != nil && !s.cropMode
        default: return ready
        }
    }
    func perform(_ command:WorkspaceCommandID) {
        guard enabled(command) else { return }
        if NSApp.currentEvent?.type == .keyDown,
           window?.firstResponder is NSTextView || window?.firstResponder is NSTextField,
           [.crop,.brush,.masks,.pixel100,.beforeOriginal,.beforeGeometry,.whiteBalance,.autoTone].contains(command) { return }
        switch command {
        case .undo: undo()
        case .redo: redo()
        case .openFolder: openFolder()
        case .export: present(.export)
        case .batch: present(.batch)
        case .merge: present(.merge)
        case .sync: present(.sync)
        case .snapshots: present(.snapshots)
        case .copy: finishEditing(); state.copyAdjustments()
        case .crop: finishEditing(); state.toggleCropMode()
        case .beforeOriginal: finishEditing(); state.showBefore.toggle()
        case .beforeGeometry: finishEditing(); state.splitComparison.toggle()
        case .fit: fit()
        case .pixel100: finishEditing(); state.oneToOne.toggle()
        case .masks:
            finishEditing(); if state.cropSession != nil { state.finishCrop() }; session.inspectorVisible = true; state.inspectorUI.category = .masks
            state.whiteBalancePicker = false; state.showBefore = false; state.splitComparison = false
        case .brush: finishEditing(); state.activateBrush()
        case .overlay: state.showMaskOverlay.toggle()
        case .whiteBalance: finishEditing(); state.showBefore = false; state.splitComparison = false; state.whiteBalancePicker.toggle()
        case .autoTone: finishEditing(); state.runAutoTone()
        case .cancelJob: state.cancelJobs()
        }
    }
}


struct WorkspaceMenuCommands: Commands {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var state: AppState
    @ObservedObject var history: History
    @FocusedValue(\.workspaceCommands) private var model
    private func available(_ id:WorkspaceCommandID) -> Bool { model?.enabled(id) == true }
    private func run(_ id:WorkspaceCommandID) { model?.perform(id) }
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Menu(L10n.tr("界面语言")) {
                ForEach(["system","zh-Hans","en"],id: \.self) { value in
                    Button { model?.finishEditing(); language.select(value) } label: {
                        if language.choice == value { Label(L10n.tr(value == "system" ? "跟随系统" : value == "en" ? "English" : "简体中文"),systemImage:"checkmark") }
                        else { Text(L10n.tr(value == "system" ? "跟随系统" : value == "en" ? "English" : "简体中文")) }
                    }
                }
            }
        }
        CommandGroup(replacing: .undoRedo) {
            Button(L10n.tr("撤销")) { run(.undo) }.keyboardShortcut("z").disabled(!available(.undo))
            Button(L10n.tr("重做")) { run(.redo) }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!available(.redo))
        }
        CommandGroup(after: .newItem) {
            Button(L10n.tr("打开文件夹…")) { run(.openFolder) }.keyboardShortcut("o").disabled(!available(.openFolder))
            Button(L10n.tr("导出当前照片…")) { run(.export) }.keyboardShortcut("e").disabled(!available(.export))
            Button(L10n.tr("裁剪")) { run(.crop) }.keyboardShortcut("r").disabled(!available(.crop))
            Button(L10n.tr("批量导出…")) { run(.batch) }.disabled(!available(.batch))
            Button(L10n.tr("取消当前处理")) { run(.cancelJob) }.disabled(!available(.cancelJob))
            Button(L10n.tr("多重曝光合成…")) { run(.merge) }.keyboardShortcut("m", modifiers: [.command, .shift]).disabled(!available(.merge))
            Button(L10n.tr("前后对比")) { run(.beforeOriginal) }.keyboardShortcut("b").disabled(!available(.beforeOriginal))
            Button(L10n.tr("同几何分割对比")) { run(.beforeGeometry) }.keyboardShortcut("b",modifiers:[.command,.option]).disabled(!available(.beforeGeometry))
            Button(L10n.tr("复制调整")) { run(.copy) }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!available(.copy))
            Button(L10n.tr("同步调整…")) { run(.sync) }.keyboardShortcut("v", modifiers: [.command, .shift]).disabled(!available(.sync))
            Button(L10n.tr("命名快照…")) { run(.snapshots) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!available(.snapshots))
        }
        CommandGroup(after: .toolbar) {
            Button(L10n.tr("A · 沉浸编辑")) { model?.session.mode = .immersive }
                .keyboardShortcut("a", modifiers: [.command, .control]).disabled(model == nil)
            Button(L10n.tr("B · 连续选片")) { model?.session.mode = .filmstrip }
                .keyboardShortcut("b", modifiers: [.command, .control]).disabled(model == nil)
            Button(L10n.tr("显示或隐藏照片浏览器")) { model?.session.browserVisible.toggle() }
                .keyboardShortcut("1", modifiers: [.command, .option]).disabled(model == nil)
            Button(L10n.tr("显示或隐藏调整面板")) { model?.session.inspectorVisible.toggle() }
                .keyboardShortcut("2", modifiers: [.command, .option]).disabled(model == nil)
            Button(L10n.tr("适合窗口")) { run(.fit) }.keyboardShortcut("0").disabled(!available(.fit))
            Button(L10n.tr("1:1 检查")) { run(.pixel100) }.keyboardShortcut("1").disabled(!available(.pixel100))
        }
    }
}
