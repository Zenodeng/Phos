import AppKit
import CoreImage
import CryptoKit

/// Every displayed result carries its own geometry and all of its related pixels.
enum PreviewPurpose: String, Codable, Sendable { case edited, cropReference, beforeOriginal, beforeGeometry }
struct PreviewFrameKey: Equatable, Sendable {
    let photoID: UUID
    let revision: UInt64
    let purpose: PreviewPurpose
    let paramsFingerprint: String
}
struct PreviewFrame: @unchecked Sendable {
    typealias Histogram = (r: [Int], g: [Int], b: [Int], l: [Int])
    let key: PreviewFrameKey
    let image: CGImage
    let mask: CGImage?
    let maskID: UUID?
    let histogram: Histogram
    /// Core Image coordinates, including the actual origin after geometry/crop.
    let renderExtent: CGRect
    let editedExtent: CGRect
    let proxyScale: CGFloat
    let fullResolution: Bool
    var bitmapSize: CGSize { CGSize(width: image.width, height: image.height) }
    static func fingerprint(_ params: EditParams) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(params)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}

/// A view transform maps only this output frame. It never pretends to invert perspective.
struct DisplayTransform {
    let outputExtent: CGRect
    let bitmapSize: CGSize
    let imageRect: CGRect
    let backingScale: CGFloat
    init(frame: PreviewFrame, imageRect: CGRect, backingScale: CGFloat = 1) {
        outputExtent = frame.editedExtent; bitmapSize = frame.bitmapSize
        self.imageRect = imageRect; self.backingScale = max(backingScale, 1)
    }
    init(outputExtent: CGRect, bitmapSize: CGSize, imageRect: CGRect, backingScale: CGFloat = 1) {
        self.outputExtent = outputExtent; self.bitmapSize = bitmapSize
        self.imageRect = imageRect; self.backingScale = max(backingScale, 1)
    }
    func normalizedPoint(_ point: CGPoint, requireInside: Bool = true) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0,
              !requireInside || imageRect.contains(point) else { return nil }
        return CGPoint(x: (point.x - imageRect.minX) / imageRect.width,
                       y: 1 - (point.y - imageRect.minY) / imageRect.height)
    }
    func outputPoint(_ point: CGPoint) -> CGPoint? {
        guard let n = normalizedPoint(point) else { return nil }
        return CGPoint(x: outputExtent.minX + n.x * outputExtent.width,
                       y: outputExtent.minY + n.y * outputExtent.height)
    }
    func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + (point.x - outputExtent.minX) / outputExtent.width * imageRect.width,
                y: imageRect.maxY - (point.y - outputExtent.minY) / outputExtent.height * imageRect.height)
    }
    var screenPixelsPerEditedPixel: CGFloat { imageRect.width * backingScale / max(outputExtent.width, 1) }
    static func rect(bitmap: CGSize, in viewport: CGRect, fill: Bool) -> CGRect {
        guard bitmap.width > 0, bitmap.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let x = viewport.width / bitmap.width, y = viewport.height / bitmap.height
        let factor = fill ? max(x, y) : min(x, y)
        let size = CGSize(width: bitmap.width * factor, height: bitmap.height * factor)
        return CGRect(x: viewport.midX - size.width / 2, y: viewport.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// Counters describe real work, rather than counting view updates as renders.
final class WorkspaceWorkMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var values = ["select": 0, "decode": 0, "render": 0, "before": 0, "thumbnail": 0, "sidecarWrite": 0, "staleFrameRejected": 0]
    func increment(_ key: String) { lock.lock(); values[key, default: 0] += 1; lock.unlock() }
    var snapshot: [String: Int] { lock.lock(); defer { lock.unlock() }; return values }
}
