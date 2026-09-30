import Foundation
import CoreImage
import CryptoKit
import Darwin

@main
struct RealPhotoTest {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else {
            throw NSError(domain: "RealPhotoTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        print("PASS: \(message)")
    }

    @MainActor
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(180)
        while !condition() {
            try checkTimeout(deadline)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    static func checkTimeout(_ deadline: Date) throws {
        if Date() > deadline {
            throw NSError(domain: "RealPhotoTest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Library/preview timeout"])
        }
    }

    static func digest(_ url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url))
    }

    static func proxy(_ image: CIImage, edge: CGFloat) -> CIImage {
        let scale = min(1, edge / max(image.extent.width, image.extent.height))
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4, let seconds = Double(args[2]), seconds >= 1, seconds.isFinite else {
            throw NSError(domain: "RealPhotoTest", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Usage: real-photo <output> <soak-seconds> <photo> [more-photos...]"
            ])
        }
        let output = URL(fileURLWithPath: args[1]).appendingPathComponent(UUID().uuidString)
        let library = output.appendingPathComponent("proxy-library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let inputs = args.dropFirst(3).map { URL(fileURLWithPath: $0) }
        let hashes = try inputs.map(digest)
        var fixtures: [URL] = []
        var rawCount = 0
        for (index, input) in inputs.enumerated() {
            guard let source = Engine.decode(input) else {
                throw NSError(domain: "RealPhotoTest", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot decode input \(index)"
                ])
            }
            try check(source.extent.width > 0 && source.extent.height > 0, "input \(index): decode \(input.pathExtension)")
            if Engine.rawSet.contains(input.pathExtension.lowercased()) { rawCount += 1 }
            let small = proxy(source, edge: 1200)
            var settings = ExportSettings()
            settings.format = "png"; settings.maxLongEdge = 1200
            let exported = output.appendingPathComponent("photo-\(index).png")
            try Engine.write(Engine.render(small, EditParams()), to: exported, settings: settings)
            let decoded = Engine.decode(exported)!
            let thumb = AppState.thumb(for: input)!
            try check((source.extent.height > source.extent.width) == (thumb.height > thumb.width),
                      "input \(index): thumbnail orientation agrees with decode")
            try check(abs(decoded.extent.width / decoded.extent.height - source.extent.width / source.extent.height) < 0.01,
                      "input \(index): export aspect/orientation preserved")
            var bitmap = [UInt8](repeating: 0, count: 64 * 64 * 4)
            let sample = decoded.transformed(by: CGAffineTransform(
                scaleX: 64 / decoded.extent.width, y: 64 / decoded.extent.height))
            Engine.ctx.render(sample, toBitmap: &bitmap, rowBytes: 256,
                              bounds: CGRect(x: 0, y: 0, width: 64, height: 64),
                              format: .RGBA8, colorSpace: Engine.srgb)
            try check(Set(bitmap).count > 32, "input \(index): export has nonblank pixels")

            for kind in [MaskKind.subject, .person, .foreground] {
                var mask = Mask(); mask.kind = kind
                guard let selection = Engine.aiMask(for: mask, extent: small.extent, analyzed: small) else {
                    print("UNVERIFIED: input \(index), Vision \(kind.rawValue) returned no mask")
                    continue
                }
                var values = [Float](repeating: 0, count: 64 * 64 * 4)
                let normalized = selection.transformed(by: CGAffineTransform(
                    scaleX: 64 / small.extent.width, y: 64 / small.extent.height))
                Engine.ctx.render(normalized, toBitmap: &values, rowBytes: 64 * 16,
                                  bounds: CGRect(x: 0, y: 0, width: 64, height: 64),
                                  format: .RGBAf, colorSpace: Engine.srgb)
                try check(values.allSatisfy(\.isFinite), "input \(index): Vision \(kind.rawValue) finite pixels")
                let coverage = stride(from: 0, to: values.count, by: 4).filter { values[$0] > 0.5 }.count
                print("VISION: input \(index), \(kind.rawValue), selected \(coverage)/4096 samples (not an accuracy score)")
                try Engine.write(selection, to: output.appendingPathComponent("mask-\(index)-\(kind.rawValue).png"), settings: settings)
                Engine.invalidateAIMask(id: mask.id)
            }
            settings.format = "jpeg"; settings.maxLongEdge = 320
            let fixture = output.appendingPathComponent("fixture-\(index).jpg")
            try Engine.write(small, to: fixture, settings: settings)
            fixtures.append(fixture)
        }
        print(rawCount > 0 ? "RAW: \(rawCount) real inputs decoded" : "UNVERIFIED: no real RAW input supplied")
        for index in 0..<1000 {
            try FileManager.default.copyItem(at: fixtures[index % fixtures.count],
                to: library.appendingPathComponent(String(format: "%04d.jpg", index)))
        }
        let state = AppState()
        state.openFolder(library)
        try await wait { state.items.count == 1000 && state.items.allSatisfy { $0.thumb != nil }
            && state.preview != nil && !state.previewing }
        try check(state.workflowError == nil, "1,000 proxy photos scanned and all thumbnails loaded")
        let start = Date()
        var iterations = 0
        while Date().timeIntervalSince(start) < seconds {
            let index = (iterations * 137 + 1) % 1000
            state.select(index)
            try await wait { state.currentIndex == index && state.source != nil
                && state.preview != nil && !state.previewing }
            state.set(\.exposure, Double(iterations % 5) / 10)
            state.endEdit()
            state.undo(); state.redo()
            try await wait { !state.previewing }
            if state.workflowError != nil {
                throw NSError(domain: "RealPhotoTest", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Soak workflow error"])
            }
            iterations += 1
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("PASS: proxy-library soak, \(iterations) selections/edits/undo/redo in \(Int(Date().timeIntervalSince(start))) seconds")
        print("METRIC: peak resident memory \(usage.ru_maxrss / 1024 / 1024) MiB; not a leak proof")
        for (index, input) in inputs.enumerated() {
            try check(try digest(input) == hashes[index], "original \(index) SHA256 unchanged")
        }
        print("ARTIFACTS: \(output.path)")
        print("LIMIT: proxy-library soak is not a full-resolution RAW library endurance test; Vision accuracy requires visual review.")
    }
}
