import Foundation

@main
enum QAWorkspaceTest {
    static func check(_ condition: Bool, _ label: String) {
        precondition(condition, label)
        print("PASS: \(label)")
    }

    static func denied(_ label: String, _ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected rejection: \(label)") }
        catch { print("PASS: \(label)") }
    }

    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let original = output.appendingPathComponent("originals", isDirectory: true)
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        let image = original.appendingPathComponent("photo.jpg")
        let imageData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        try imageData.write(to: image)
        let initial = try JSONEncoder().encode(Sidecar(params: EditParams(), rating: 2))
        try initial.write(to: SidecarStore.url(for: image))
        let scope = QAWorkspace.scope
        let copyFolder = try scope.importFolder(original, extensions: ["jpg"])
        let copy = copyFolder.appendingPathComponent("photo.jpg")
        check(copyFolder != original && copyFolder.path.hasPrefix(scope.photos.path + "/"), "import uses owned copies")
        check(try Data(contentsOf: copy) == imageData, "image bytes preserved")
        check(SidecarStore.load(for: copy)?.rating == 2, "existing edit state copied")
        try SidecarStore.write(Sidecar(params: EditParams(), rating: 5), for: copy)
        check(SidecarStore.load(for: copy)?.rating == 5, "real sidecar writer updates copy")
        check(try Data(contentsOf: SidecarStore.url(for: image)) == initial, "original sidecar unchanged")
        denied("real sidecar writer rejects original") { try SidecarStore.write(Sidecar(params: EditParams()), for: image) }
        let sibling = URL(fileURLWithPath: scope.photos.path + "-outside", isDirectory: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        let siblingImage = sibling.appendingPathComponent("photo.jpg")
        try imageData.write(to: siblingImage)
        denied("similar path prefix rejected") { try scope.requireWritableImage(siblingImage) }
        let link = copyFolder.appendingPathComponent("linked.jpg")
        try fm.createSymbolicLink(at: link, withDestinationURL: image)
        denied("photo symlink rejected") { try scope.requireWritableImage(link) }
        let sidecar = SidecarStore.url(for: copy)
        try fm.removeItem(at: sidecar)
        try fm.createSymbolicLink(at: sidecar, withDestinationURL: SidecarStore.url(for: image))
        denied("sidecar symlink rejected") { try SidecarStore.write(Sidecar(params: EditParams()), for: copy) }
        try fm.removeItem(at: sidecar)
        try Data("damaged".utf8).write(to: sidecar)
        denied("damaged copied sidecar preserved") { try SidecarStore.write(Sidecar(params: EditParams()), for: copy) }
        check(try Data(contentsOf: sidecar) == Data("damaged".utf8), "damaged bytes unchanged")
        let linkedFolder = scope.photos.appendingPathComponent("linked-directory", isDirectory: true)
        try fm.createSymbolicLink(at: linkedFolder, withDestinationURL: original)
        denied("directory symlink escape rejected") { try scope.requireWritableImage(linkedFolder.appendingPathComponent("photo.jpg")) }
        let badInput = output.appendingPathComponent("linked-input", isDirectory: true)
        try fm.createDirectory(at: badInput, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: badInput.appendingPathComponent("photo.jpg"), withDestinationURL: image)
        denied("import refuses symlink inputs") { _ = try scope.importFolder(badInput, extensions: ["jpg"]) }
        let redirected = QAFileScope(root: output.appendingPathComponent("redirected-root"))
        try fm.createDirectory(at: redirected.root, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: redirected.photos, withDestinationURL: original)
        denied("photos root symlink rejected") { _ = try redirected.importFolder(original, extensions: ["jpg"]) }
        let state = AppState()
        state.openFolder(original)
        check(state.folder != original && state.folder?.path.hasPrefix(scope.photos.path + "/") == true,
              "actual AppState opens a copy directory")
        check(state.presetsURL == QAWorkspace.presetsURL, "presets isolated")
        check(state.savePresets(state.defaultPresets), "QA preset write succeeds")
        check(ExportPaths.defaultDir.standardizedFileURL.path == QAWorkspace.exports.standardizedFileURL.path,
              "default export isolated")
        check(try Data(contentsOf: image) == imageData, "original image unchanged")
        check(try Data(contentsOf: SidecarStore.url(for: image)) == initial, "original edits unchanged after integration checks")
        try Data("{\"status\":\"passed\",\"checks\":20,\"nativeWindowLaunched\":false}".utf8)
            .write(to: output.appendingPathComponent("qa-safety-results.json"))
    }
}
