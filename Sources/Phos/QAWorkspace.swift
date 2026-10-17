import Foundation

#if PHOS_QA
/// QA builds edit owned copies. Production builds do not include this policy.
struct QAFileScope {
    let root: URL
    var photos: URL { root.appendingPathComponent("photos", isDirectory: true) }

    private func contains(_ url: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("photos", isDirectory: true).path + "/"
        return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base)
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    func requireWritableImage(_ url: URL) throws {
        guard contains(url), contains(SidecarStore.url(for: url)) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try requireRegularFile(url)
        for sidecar in [SidecarStore.url(for: url), SidecarStore.existingURL(for: url)] {
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try requireRegularFile(sidecar)
            }
        }
    }

    func importFolder(_ source: URL, extensions: Set<String>) throws -> URL {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard photos.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath()
            .appendingPathComponent("photos").path else { throw CocoaError(.fileWriteNoPermission) }
        if contains(source) { return source }
        let files = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { extensions.contains($0.pathExtension.lowercased()) }
        let destination = photos.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            for image in files {
                try requireRegularFile(image)
                try fm.copyItem(at: image, to: destination.appendingPathComponent(image.lastPathComponent))
                let sidecars = Set([SidecarStore.url(for: image), SidecarStore.existingURL(for: image)])
                for sidecar in sidecars where fm.fileExists(atPath: sidecar.path) {
                    try requireRegularFile(sidecar)
                    try fm.copyItem(at: sidecar, to: destination.appendingPathComponent(sidecar.lastPathComponent))
                }
            }
            return destination
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }
}

enum QAWorkspace {
    static var root: URL {
        #if PHOS_TESTING
        if let path = ProcessInfo.processInfo.environment["PHOS_QA_TEST_ROOT"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        if let path = Bundle.main.object(forInfoDictionaryKey: "PhosQAWorkspace") as? String {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Phos-QA", isDirectory: true)
    }
    static var scope: QAFileScope { QAFileScope(root: root) }
    static var fixtureFolder: URL { root.appendingPathComponent("photos/fixtures", isDirectory: true) }
    static var presetsURL: URL { root.appendingPathComponent("settings/presets.json") }
    static var exports: URL { root.appendingPathComponent("exports", isDirectory: true) }
}
#endif
