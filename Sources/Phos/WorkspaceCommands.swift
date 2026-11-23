import SwiftUI
import AppKit

enum WorkspaceCommandID: String, CaseIterable {
    case undo, redo, openFolder, export, batch, merge, crop, beforeOriginal, beforeGeometry
    case copy, sync, snapshots, fit, pixel100, masks, brush, overlay, whiteBalance, autoTone, cancelJob
    case clipping, reject, gridView, compareView, surveyView, referenceView, toggleEDR
    case createVirtualCopy, deleteVirtualCopy, exportXMP, importXMP, exportFolderXMP, toggleAutoSyncXMP
    case retouchTool, pointColorTool
    case nativeAIWorkspace, colorMatchTool, smartCulling, modelHub
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
        case .pixel100,.beforeOriginal,.beforeGeometry,.clipping,.compareView,.referenceView,.retouchTool,.pointColorTool:
            return ready && !s.cropMode
        case .reject,.createVirtualCopy,.exportXMP,.importXMP:
            return s.current != nil && !s.syncRunning
        case .deleteVirtualCopy:
            return s.current?.isVirtualCopy == true && !s.syncRunning
        case .gridView,.surveyView,.exportFolderXMP,.smartCulling:
            return !s.items.isEmpty && !s.syncRunning
        case .toggleEDR,.toggleAutoSyncXMP,.nativeAIWorkspace,.colorMatchTool,.modelHub:
            return true
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
           [.crop,.brush,.masks,.pixel100,.beforeOriginal,.beforeGeometry,.whiteBalance,.autoTone,.clipping,.reject,.gridView,.compareView,.surveyView,.referenceView,.retouchTool,.pointColorTool].contains(command) { return }
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
            state.whiteBalancePicker = false; state.pointColorPicker = false; state.retouchActive = false; state.showBefore = false; state.splitComparison = false
        case .brush: finishEditing(); state.activateBrush()
        case .overlay: state.showMaskOverlay.toggle()
        case .whiteBalance: finishEditing(); state.showBefore = false; state.splitComparison = false; state.bokehFocusPicker = false; state.whiteBalancePicker.toggle()
        case .autoTone: finishEditing(); state.runAutoTone()
        case .cancelJob: state.cancelJobs()
        case .clipping: state.showClippingWarning.toggle()
        case .reject: finishEditing(); state.toggleReject()
        case .gridView: finishEditing(); state.canvasDisplayMode = state.canvasDisplayMode == .grid ? .single : .grid
        case .compareView: finishEditing(); state.canvasDisplayMode = state.canvasDisplayMode == .compare ? .single : .compare
        case .surveyView:
            finishEditing()
            if state.canvasDisplayMode == .compare && state.compareSubMode == .survey {
                state.canvasDisplayMode = .single
            } else {
                state.compareSubMode = .survey
                state.canvasDisplayMode = .compare
            }
        case .referenceView: finishEditing(); state.canvasDisplayMode = state.canvasDisplayMode == .reference ? .single : .reference
        case .toggleEDR: state.edrEnabled.toggle()
        case .createVirtualCopy: finishEditing(); state.createVirtualCopy()
        case .deleteVirtualCopy: finishEditing(); state.deleteVirtualCopy()
        case .exportXMP: finishEditing(); state.exportCurrentXMP()
        case .importXMP: finishEditing(); state.importXMP()
        case .exportFolderXMP: finishEditing(); state.exportFolderXMP()
        case .toggleAutoSyncXMP: state.autoSyncXMP.toggle()
        case .retouchTool:
            finishEditing(); session.inspectorVisible = true; state.inspectorUI.category = .detail
            state.retouchActive.toggle()
        case .pointColorTool:
            finishEditing(); session.inspectorVisible = true; state.inspectorUI.category = .color
            state.localPointColorMaskID = nil
            state.pointColorPicker.toggle()
        case .nativeAIWorkspace:
            finishEditing(); state.nativeAITab = .edit; state.showNativeAI = true
        case .colorMatchTool:
            finishEditing(); state.nativeAITab = .colorMatch; state.showNativeAI = true
        case .smartCulling:
            finishEditing()
            if state.cullingRunning { state.cancelSmartCulling() }
            else { state.runSmartCulling() }
        case .modelHub:
            finishEditing(); state.nativeAITab = .models; state.showNativeAI = true
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
            Divider()
            Button(L10n.tr("创建虚拟副本")) { run(.createVirtualCopy) }.keyboardShortcut("'", modifiers: [.command]).disabled(!available(.createVirtualCopy))
            Button(L10n.tr("删除虚拟副本")) { run(.deleteVirtualCopy) }.disabled(!available(.deleteVirtualCopy))
            Button(L10n.tr("导出当前 XMP 旁档")) { run(.exportXMP) }.disabled(!available(.exportXMP))
            Button(L10n.tr("从 XMP 旁档读取")) { run(.importXMP) }.disabled(!available(.importXMP))
            Button(L10n.tr("批量导出 XMP 旁档")) { run(.exportFolderXMP) }.disabled(!available(.exportFolderXMP))
            Toggle(L10n.tr("自动写入 XMP 旁档"), isOn: $state.autoSyncXMP)
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
            Divider()
            Button(L10n.tr("单张视图")) { model?.state.canvasDisplayMode = .single }.disabled(model == nil)
            Button(L10n.tr("网格看片视图 (G)")) { run(.gridView) }.disabled(!available(.gridView))
            Button(L10n.tr("双图同步对比 (C)")) { run(.compareView) }.disabled(!available(.compareView))
            Button(L10n.tr("多图同屏选片 (N)")) { run(.surveyView) }.disabled(!available(.surveyView))
            Button(L10n.tr("参考锁定视图 (⇧R)")) { run(.referenceView) }.disabled(!available(.referenceView))
            Button(L10n.tr("高光/暗部溢出警示 (J)")) { run(.clipping) }.disabled(!available(.clipping))
            Button(L10n.tr("切换 EDR 动态范围")) { run(.toggleEDR) }.disabled(!available(.toggleEDR))
            Button(L10n.tr("污点修复画笔")) { run(.retouchTool) }.disabled(!available(.retouchTool))
            Button(L10n.tr("点颜色取样")) { run(.pointColorTool) }.disabled(!available(.pointColorTool))
            Button(L10n.tr("淘汰 / 取消淘汰 (X)")) { run(.reject) }.disabled(!available(.reject))
            Divider()
            Button(L10n.tr("端侧原生 AI 工作台…")) { run(.nativeAIWorkspace) }.disabled(!available(.nativeAIWorkspace))
            Button(L10n.tr("参考图智能对色…")) { run(.colorMatchTool) }.disabled(!available(.colorMatchTool))
            Button(L10n.tr("智能挑片分析")) { run(.smartCulling) }.disabled(!available(.smartCulling))
            Button(L10n.tr("端侧 Core ML 模型中心…")) { run(.modelHub) }.disabled(!available(.modelHub))
        }
    }
}
