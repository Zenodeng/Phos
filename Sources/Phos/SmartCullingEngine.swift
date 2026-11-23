import Foundation
import CoreGraphics
import CoreImage
import Vision

enum CullingFilter: String, CaseIterable {
    case all
    case bestShots
    case eyesClosed
    case blurry
    case bursts

    var label: String {
        switch self {
        case .all: return "全部照片"
        case .bestShots: return "智能最佳"
        case .eyesClosed: return "闭眼警告"
        case .blurry: return "模糊/跑焦"
        case .bursts: return "连拍精选"
        }
    }
}

struct PhotoCullMetrics: Codable, Equatable {
    var sharpnessScore: Double = 0
    var exposureScore: Double = 0
    var eyesClosed: Bool = false
    var isBlurry: Bool = false
    var faceCount: Int = 0
    var burstGroupID: Int? = nil
    var isBurstBest: Bool = false
    var overallScore: Double = 0
    var semanticTags: [String] = []
    var ocrText: String = ""
}

/// P3 本地智能挑片与语义索引引擎（Vision 人脸眼睑 + 注意力焦点锐度 + 连拍特征聚类 + OCR/分类索引）。
enum SmartCullingEngine {
    private struct CachedRecord: Codable {
        var mtime: TimeInterval
        var fileSize: Int64
        var metrics: PhotoCullMetrics
    }

    private static let cacheLock = NSLock()
    private static var diskIndex: [String: CachedRecord]? = nil

    private static var indexURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("Phos/SmartIndex.json")
    }

    static func cachedMetrics(for url: URL) -> PhotoCullMetrics? {
        guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = vals.contentModificationDate?.timeIntervalSince1970,
              let size = vals.fileSize else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if diskIndex == nil {
            if let data = try? Data(contentsOf: indexURL),
               let decoded = try? JSONDecoder().decode([String: CachedRecord].self, from: data) {
                diskIndex = decoded
            } else {
                diskIndex = [:]
            }
        }
        if let hit = diskIndex?[url.path], abs(hit.mtime - mtime) < 1.0, hit.fileSize == Int64(size) {
            return hit.metrics
        }
        return nil
    }

    static func saveCachedMetrics(_ metrics: PhotoCullMetrics, for url: URL) {
        guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = vals.contentModificationDate?.timeIntervalSince1970,
              let size = vals.fileSize else { return }
        cacheLock.lock()
        if diskIndex == nil { diskIndex = [:] }
        diskIndex?[url.path] = CachedRecord(mtime: mtime, fileSize: Int64(size), metrics: metrics)
        let snapshot = diskIndex
        cacheLock.unlock()

        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    static func analyzeImage(_ cgImage: CGImage, captureDate: Date? = nil) -> (metrics: PhotoCullMetrics, feature: VNFeaturePrintObservation?) {
        _ = captureDate
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let faceReq = VNDetectFaceLandmarksRequest()
        let salReq = VNGenerateAttentionBasedSaliencyImageRequest()
        let clsReq = VNClassifyImageRequest()
        let ocrReq = VNRecognizeTextRequest()
        ocrReq.recognitionLevel = .fast
        ocrReq.usesLanguageCorrection = false
        ocrReq.recognitionLanguages = ["zh-Hans", "en-US"]
        let fpReq = VNGenerateImageFeaturePrintRequest()

        try? handler.perform([faceReq, salReq, clsReq, ocrReq, fpReq])

        var eyesClosed = false
        var focusROIs: [CGRect] = []
        let faces = faceReq.results ?? []
        for face in faces {
            focusROIs.append(face.boundingBox)
            if let lm = face.landmarks {
                let leftEAR = lm.leftEye.map { eyeAspectRatio($0.normalizedPoints) }
                let rightEAR = lm.rightEye.map { eyeAspectRatio($0.normalizedPoints) }
                let closedL = leftEAR.map { $0 < 0.17 } ?? false
                let closedR = rightEAR.map { $0 < 0.17 } ?? false
                if closedL || closedR {
                    eyesClosed = true
                }
            }
        }

        if focusROIs.isEmpty, let salObs = salReq.results?.first as? VNSaliencyImageObservation,
           let objs = salObs.salientObjects, !objs.isEmpty {
            for obj in objs.prefix(3) {
                focusROIs.append(obj.boundingBox)
            }
        }
        if focusROIs.isEmpty {
            focusROIs = [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)]
        }

        let sharp = computeSharpnessScore(cgImage: cgImage, normalizedROIs: focusROIs)
        let expScore = computeExposureScore(cgImage: cgImage)
        let isBlurry = sharp < 28.0

        var tags: [String] = []
        if let cls = clsReq.results {
            tags = cls.filter { $0.confidence >= 0.12 }
                .prefix(15)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ").lowercased() }
        }
        var ocrTokens: [String] = []
        if let obs = ocrReq.results {
            for item in obs.prefix(12) {
                if let top = item.topCandidates(1).first?.string {
                    ocrTokens.append(top)
                }
            }
        }
        let ocrStr = String(ocrTokens.joined(separator: " ").prefix(280))

        let overall = min(max(sharp * 0.62 + expScore * 0.38 - (eyesClosed ? 32.0 : 0.0) - (isBlurry ? 18.0 : 0.0), 0), 100)
        let metrics = PhotoCullMetrics(
            sharpnessScore: sharp,
            exposureScore: expScore,
            eyesClosed: eyesClosed,
            isBlurry: isBlurry,
            faceCount: faces.count,
            burstGroupID: nil,
            isBurstBest: false,
            overallScore: overall,
            semanticTags: tags,
            ocrText: ocrStr
        )
        let feature = fpReq.results?.first as? VNFeaturePrintObservation
        return (metrics, feature)
    }

    static func featurePrint(for cgImage: CGImage) -> VNFeaturePrintObservation? {
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([req])
        return req.results?.first as? VNFeaturePrintObservation
    }

    static func assignBurstGroups(entries: [(id: UUID, date: Date?, feature: VNFeaturePrintObservation?, metrics: PhotoCullMetrics)]) -> [UUID: PhotoCullMetrics] {
        var result: [UUID: PhotoCullMetrics] = [:]
        for item in entries {
            var m = item.metrics
            m.burstGroupID = nil
            m.isBurstBest = false
            result[item.id] = m
        }
        guard entries.count >= 2 else { return result }

        var groups: [[UUID]] = []
        var curGroup: [UUID] = [entries[0].id]
        for i in 1..<entries.count {
            let prev = entries[i - 1]
            let cur = entries[i]
            var closeInTime = false
            if let d0 = prev.date, let d1 = cur.date {
                closeInTime = abs(d1.timeIntervalSince(d0)) <= 6.0
            }
            var visuallySimilar = false
            if let f0 = prev.feature, let f1 = cur.feature {
                var dist: Float = .greatestFiniteMagnitude
                try? f0.computeDistance(&dist, to: f1)
                let threshold: Float = (prev.date != nil && cur.date != nil) ? 0.72 : 0.45
                visuallySimilar = dist < threshold
            }
            if (prev.date == nil || cur.date == nil ? visuallySimilar : (closeInTime && visuallySimilar)) {
                curGroup.append(cur.id)
            } else {
                groups.append(curGroup)
                curGroup = [cur.id]
            }
        }
        groups.append(curGroup)

        var nextBurstID = 1
        for g in groups where g.count >= 2 {
            let bid = nextBurstID
            nextBurstID += 1
            var bestID = g[0]
            var bestRank = -Double.greatestFiniteMagnitude
            for id in g {
                guard var m = result[id] else { continue }
                m.burstGroupID = bid
                result[id] = m
                let rank = m.overallScore + (m.eyesClosed ? -100.0 : 25.0) + (m.isBlurry ? -40.0 : 10.0)
                if rank > bestRank {
                    bestRank = rank
                    bestID = id
                }
            }
            if var bestM = result[bestID] {
                bestM.isBurstBest = true
                result[bestID] = bestM
            }
        }
        return result
    }

    private static func eyeAspectRatio(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 4 else { return 0.3 }
        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let w = max(maxX - minX, 1e-4)
        let h = max(maxY - minY, 0)
        return h / w
    }

    private static func computeSharpnessScore(cgImage: CGImage, normalizedROIs: [CGRect]) -> Double {
        let maxSide = 256
        let iw = cgImage.width, ih = cgImage.height
        guard iw >= 4, ih >= 4 else { return 0 }
        let scale = min(1.0, Double(maxSide) / Double(max(iw, ih)))
        let w = max(8, Int((Double(iw) * scale).rounded()))
        let h = max(8, Int((Double(ih) * scale).rounded()))
        var gray = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return 0
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var mask = [Bool](repeating: false, count: w * h)
        for roi in normalizedROIs {
            let x0 = max(1, Int((roi.minX * CGFloat(w)).rounded(.down)))
            let x1 = min(w - 2, Int((roi.maxX * CGFloat(w)).rounded(.up)))
            // Vision boundingBox y 向上，转回 top-down 行号
            let yTop = max(1, Int(((1.0 - roi.maxY) * CGFloat(h)).rounded(.down)))
            let yBot = min(h - 2, Int(((1.0 - roi.minY) * CGFloat(h)).rounded(.up)))
            if x1 > x0, yBot > yTop {
                for y in yTop...yBot {
                    for x in x0...x1 {
                        mask[y * w + x] = true
                    }
                }
            }
        }

        var energySum = 0.0
        var count = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let idx = y * w + x
                if !mask[idx] { continue }
                let c = Double(gray[idx]) / 255.0
                let gx = (Double(gray[idx + 1]) - Double(gray[idx - 1])) / 255.0
                let gy = (Double(gray[idx + w]) - Double(gray[idx - w])) / 255.0
                let nbr = (Double(gray[idx + 1]) + Double(gray[idx - 1]) + Double(gray[idx + w]) + Double(gray[idx - w])) / 255.0
                let lap = abs(4.0 * c - nbr)
                energySum += (gx * gx + gy * gy) * 0.5 + lap * lap * 1.4
                count += 1
            }
        }
        if count == 0 {
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let idx = y * w + x
                    let c = Double(gray[idx]) / 255.0
                    let gx = (Double(gray[idx + 1]) - Double(gray[idx - 1])) / 255.0
                    let gy = (Double(gray[idx + w]) - Double(gray[idx - w])) / 255.0
                    let nbr = (Double(gray[idx + 1]) + Double(gray[idx - 1]) + Double(gray[idx + w]) + Double(gray[idx - w])) / 255.0
                    let lap = abs(4.0 * c - nbr)
                    energySum += (gx * gx + gy * gy) * 0.5 + lap * lap * 1.4
                    count += 1
                }
            }
        }
        guard count > 0 else { return 0 }
        let rms = sqrt(energySum / Double(count))
        // rms ~ 0.005 (极糊) ... 0.14+ (极锐)
        return min(max(rms / 0.11 * 100.0, 0), 100)
    }

    private static func computeExposureScore(cgImage: CGImage) -> Double {
        let side = 48
        var gray = [UInt8](repeating: 0, count: side * side)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &gray, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return 50
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        var clippedHi = 0, clippedLo = 0, sum = 0.0
        for b in gray {
            let v = Double(b) / 255.0
            sum += v
            if v > 0.985 { clippedHi += 1 }
            if v < 0.015 { clippedLo += 1 }
        }
        let n = Double(side * side)
        let mean = sum / n
        let hiRatio = Double(clippedHi) / n
        let loRatio = Double(clippedLo) / n
        let centerPenalty = abs(mean - 0.45) * 45.0
        let clipPenalty = (hiRatio + loRatio) * 140.0
        return min(max(100.0 - centerPenalty - clipPenalty, 0), 100)
    }
}
