import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WorkspaceWindowModel: ObservableObject {
    let state: AppState
    let session: WorkspaceSessionState
    let selection: PhotoSelectionController
    let environment = WorkspaceEnvironment()
    let router: WorkspaceSheetRouter
    weak var window: NSWindow?
    private(set) var folderPanel: NSOpenPanel?

    init(state: AppState, session: WorkspaceSessionState? = nil) {
        self.state = state
        self.session = session ?? WorkspaceSessionState()
        selection = PhotoSelectionController(state: state)
        router = WorkspaceSheetRouter(state: state)
        state.workspaceSession = self.session
    }

    func finishEditing() { selection.finishEditing() }
    func undo() { state.undo() }
    func redo() { state.redo() }
    func fit() {
        state.oneToOne = false
        session.viewport.mode = .fit
        state.canvasResetID = UUID()
    }
    func openFolder() {
        guard !state.syncRunning, let window, window.attachedSheet == nil, folderPanel == nil, router.presented == nil else { return }
        finishEditing()
        let panel = Self.makeFolderPanel(directory: state.folder)
        folderPanel = panel
        router.nativePanelOpen = true
        // The current host also reproduces a disabled directory confirmation in a
        // minimal AppKit sheet. The native application-modal panel validates normally.
        let response = panel.runModal()
        folderPanel = nil
        router.nativePanelOpen = false
        if response == .OK, let url = panel.url { state.openFolder(url) }
        DispatchQueue.main.async { [weak self] in self?.router.resumePending() }
    }
    static func makeFolderPanel(directory: URL?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder]
        panel.prompt = "选择文件夹"
        panel.directoryURL = directory
        return panel
    }
    func present(_ route: WorkspacePresentation) {
        finishEditing()
        router.request(route)
    }
    func savePreset() {
        guard let window, window.attachedSheet == nil, router.presented == nil, state.source != nil else { return }
        finishEditing()
        let alert = NSAlert(); alert.messageText = "保存预设"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "预设名称"; alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            var presets = state.loadPresets()
            presets.append(Preset(name: name, params: state.params)); state.savePresets(presets)
        }
    }
}

private struct WorkspaceCommandsKey: FocusedValueKey { typealias Value = WorkspaceWindowModel }
extension FocusedValues {
    var workspaceCommands: WorkspaceWindowModel? {
        get { self[WorkspaceCommandsKey.self] }
        set { self[WorkspaceCommandsKey.self] = newValue }
    }
}

struct WorkspaceWindow: View {
    @StateObject private var model: WorkspaceWindowModel
    init(state: AppState) { _model = StateObject(wrappedValue: WorkspaceWindowModel(state: state)) }
    var body: some View {
        WorkspaceWindowContent(model: model, router: model.router)
            .environmentObject(model.state)
            .focusedSceneValue(\.workspaceCommands, model)
            .task { model.state.checkForUpdates(silent: true) }
    }
}

private struct WorkspaceWindowContent: View {
    @ObservedObject var model: WorkspaceWindowModel
    @ObservedObject var router: WorkspaceSheetRouter
    @AppStorage("rf.appearance") private var appearance = "system"
    var body: some View {
        WorkspaceHost(model: model)
            .ignoresSafeArea()
            .frame(minWidth: WorkspaceLayout.minimumSize.width, minHeight: WorkspaceLayout.minimumSize.height)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .sheet(item: Binding(get: { router.presented }, set: { if $0 == nil { router.beginDismissal() } }),
                   onDismiss: { router.didDismiss() }) { route in
                WorkspaceSheetContent(route: route, model: model)
                    .environmentObject(model.state).tint(WorkspaceTokens.accent)
            }
            .onExitCommand { if model.state.cropSession != nil { model.state.cancelCrop() } else if model.state.parameterEdits.token != nil { model.state.parameterEdits.invalidate() } else { model.state.cancelMaskDrawing() } }
    }
}

private struct WorkspaceSheetContent: View {
    let route: WorkspacePresentation
    @ObservedObject var model: WorkspaceWindowModel
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var body: some View {
        switch route {
        case .photoAI: PhotoAISheet()
        case .export: ExportSheet()
        case .batch: BatchSheet()
        case .merge: MergeSheet()
        case .sync: SyncSheet()
        case .snapshots: SnapshotSheet()
        case .error, .update:
            VStack(alignment: .leading, spacing: 16) {
                Label(route == .error ? "操作未完成" : "检查更新", systemImage: route == .error ? "exclamationmark.triangle" : "arrow.down.circle")
                    .font(.headline)
                Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if route == .update, model.state.availableUpdate != nil {
                        Button("前往下载") { model.state.openUpdatePage(); dismiss() }
                    }
                    Button("好") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 390)
        }
    }
    private var message: String {
        if route == .error { return model.router.errorMessage }
        if let update = model.state.availableUpdate { return "发现新版本 \(update.version)（当前 \(UpdateChecker.currentVersion)）。" }
        return "已是最新版本 \(UpdateChecker.currentVersion)。"
    }
}
