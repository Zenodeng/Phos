import SwiftUI
import AppKit
import CoreImage

@main
struct StudioLayoutTest {
    @MainActor
    static func snapshot<V: View>(_ view: V, state: AppState, scheme: ColorScheme,
                                  size: CGSize, name: String, output: URL) async throws {
        let root = view.background(StudioStyle.panel).tint(StudioStyle.accent)
            .environmentObject(state).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        precondition(host.fittingSize.width <= size.width + 1, "\(name): UI exceeds window width: \(host.fittingSize)")
        precondition(host.fittingSize.height <= size.height + 1, "\(name): UI exceeds window height: \(host.fittingSize)")
        window.contentView = nil
        print("PASS: \(name)")
    }

    @MainActor
    static func navigationTests() {
        let state = AppState()
        state.items = (0..<6).map {
            PhotoItem(url: URL(fileURLWithPath: "/test/\($0).png"), rating: $0, picked: $0 % 2 == 0)
        }
        precondition(state.visiblePhotoIndices == [0, 1, 2, 3, 4, 5])
        precondition(state.previousVisiblePhotoIndex == nil && state.nextVisiblePhotoIndex == 1)
        state.filterRating = 2
        state.filterPicked = true
        precondition(state.visiblePhotoIndices == [2, 4])
        precondition(state.visiblePhotoPosition == nil && state.nextVisiblePhotoIndex == 2)
        state.currentIndex = 2
        precondition(state.visiblePhotoPosition == 1 && state.previousVisiblePhotoIndex == nil && state.nextVisiblePhotoIndex == 4)
        state.currentIndex = 4
        precondition(state.visiblePhotoPosition == 2 && state.previousVisiblePhotoIndex == 2 && state.nextVisiblePhotoIndex == nil)
        state.currentIndex = 3
        precondition(state.visiblePhotoPosition == nil && state.previousVisiblePhotoIndex == 2 && state.nextVisiblePhotoIndex == 4)
        state.filterRating = 5
        precondition(state.visiblePhotoIndices.isEmpty && state.previousVisiblePhotoIndex == nil && state.nextVisiblePhotoIndex == nil)
        state.filterRating = 0
        state.filterPicked = false
        precondition(state.visiblePhotoIndices.count == 6 && state.visiblePhotoPosition == 4)
        state.items = []
        precondition(state.visiblePhotoPosition == nil && state.previousVisiblePhotoIndex == nil && state.nextVisiblePhotoIndex == nil)
        print("PASS: rating/pick filters, navigation, hidden selection, boundaries and empty results")
    }

    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { fatalError("Usage: layout-test <image> <output-directory>") }
        let output = URL(fileURLWithPath: args[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        navigationTests()
        let state = AppState()
        let imageURL = URL(fileURLWithPath: args[1])
        guard let image = Engine.decode(imageURL), let cg = Engine.ctx.createCGImage(image, from: image.extent) else {
            fatalError("Test image unavailable")
        }
        state.items = (0..<12).map { i in
            PhotoItem(url: URL(fileURLWithPath: "/test/Photo-\(i).png"), rating: i % 6, picked: i % 3 == 0, thumb: cg)
        }
        state.folder = URL(fileURLWithPath: "/test/Studio layout fixtures")
        state.source = image
        state.sourceSize = image.extent.size
        state.preview = cg
        state.hist = Engine.histogram(image)
        state.history.push(state.params)

        let history = History()
        let base = EditParams()
        var changed = base; changed.exposure = 1
        history.push(base); history.push(changed)
        _ = history.undo()
        history.push(base)
        precondition(history.canRedo, "No-op edit must preserve redo")
        history.push(changed)
        precondition(history.index == 1 && !history.canRedo, "Edit after undo must branch correctly")

        for scheme in [ColorScheme.dark, .light] {
            let theme = scheme == .dark ? "dark" : "light"
            for size in [CGSize(width: 1100, height: 700), CGSize(width: 1680, height: 1050)] {
                for (index, category) in InspectorCategory.allCases.enumerated() {
                    try await snapshot(StudioMainWindow(initialInspectorCategory: category),
                                       state: state, scheme: scheme, size: size,
                                       name: "studio-\(theme)-\(Int(size.width))-tab\(index)", output: output)
                }
            }
            for watermark in [false, true] {
                state.exportSettings.watermarkEnabled = watermark
                state.exportSettings.format = "tiff"
                let suffix = watermark ? "watermark" : "plain"
                try await snapshot(ExportSheet(), state: state, scheme: scheme,
                                   size: CGSize(width: 430, height: 650),
                                   name: "export-\(theme)-\(suffix)", output: output)
                try await snapshot(BatchSheet(), state: state, scheme: scheme,
                                   size: CGSize(width: 430, height: 650),
                                   name: "batch-\(theme)-\(suffix)", output: output)
            }
            try await snapshot(SyncSheet(), state: state, scheme: scheme,
                               size: CGSize(width: 420, height: 650), name: "sync-\(theme)", output: output)
            try await snapshot(SnapshotSheet(), state: state, scheme: scheme,
                               size: CGSize(width: 460, height: 500), name: "snapshots-\(theme)", output: output)
            try await snapshot(MergeSheet(), state: state, scheme: scheme,
                               size: CGSize(width: 470, height: 700), name: "merge-\(theme)", output: output)
        }
        print("PASS: history branching and layout snapshots")
    }
}
