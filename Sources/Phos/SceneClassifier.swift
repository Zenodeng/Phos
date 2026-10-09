import Foundation
import CoreImage
import CoreGraphics
import Vision

// MARK: - 场景识别
//
// 用系统自带的 `VNClassifyImageRequest` 给照片归类，让自动影调能按题材换策略：
// 人像要护肤色、夜景要克制提亮、雪景不能压暗、截图根本不需要修图。
//
// 为什么用 Vision 而不是自己训模型：它随系统走，**不增加安装包体积、不需要联网**，
// 对免费分发、还要过公证的项目来说这是唯一现实的选择。
//
// 场景划分刻意做得**粗**。实测 Vision 会把一张山景同时打上 sky / blue_sky / cloud，
// 把海岸打成 water / rocks / structure —— 再细分下去只会得到一堆看着很具体、
// 实际互相打架的标签。这里只保留「策略真的不一样」的那几类，其余统一走通用。

/// 画面场景。`other` 表示没识别出明显题材，走通用策略。
enum PhotoScene: String, CaseIterable, Identifiable, Sendable {
    case portrait, landscape, night, snow, food, document, other

    var id: Self { self }

    var label: String {
        switch self {
        case .portrait:  return "人像"
        case .landscape: return "风光"
        case .night:     return "夜景"
        case .snow:      return "雪景"
        case .food:      return "美食"
        case .document:  return "文档截图"
        case .other:     return "通用"
        }
    }

    /// 一句话说明这一类会怎么调，直接给 UI 当提示用
    var hint: String {
        switch self {
        case .portrait:  return "护肤色：少加饱和与对比"
        case .landscape: return "风光：去朦胧与层次拉得更足"
        case .night:     return "夜景：克制提亮，补一点降噪"
        case .snow:      return "雪景：不压暗，护住雪面高光"
        case .food:      return "美食：略暖，饱和足一点"
        case .document:  return "文档截图：基本不做处理"
        case .other:     return "通用策略"
        }
    }
}

/// 识别结果。`top` 保留原始标签，出问题时能直接看出 Vision 到底认成了什么。
struct SceneGuess: Equatable, Sendable {
    var scene: PhotoScene = .other
    /// 最强命中标签的原始置信度（不是累加得分 —— 得分会随命中标签数量膨胀，
    /// 一个只命中单个 39% 标签的题材能算出 0.98 的假高置信度）
    var confidence: Double = 0
    var top: [String] = []

    /// 置信度太低时只按比例采纳，等于基本走通用策略。
    /// 0.20 以下不采纳，0.50 以上完全采纳 —— Vision 对非显而易见的题材很少给过 50%。
    var blend: Double { min(max((confidence - 0.20) / 0.30, 0), 1) }
}

enum SceneClassifier {

    /// 识别用的长边像素数。分类模型自己会缩放，喂太大只是白花时间。
    static let sampleEdge: CGFloat = 448
    /// 只看前若干个标签，再往后都是置信度极低的噪声
    static let topN = 20
    /// 最强命中标签低于这个置信度就直接判「通用」。
    ///
    /// 没有这道闸，纯噪声也能选出个「冠军」：实测一批抽象壁纸，
    /// 最强的命中标签只有 "document 1%" / "food 2%" / "moon 6%"，
    /// 却照样被判成文档截图和美食 —— 而文档策略是「什么都不动」，
    /// 真照片被这么误判就等于自动失效了。
    static let minConfidence = 0.15

    /// 每个场景的关键词。
    private static let keywords: [(PhotoScene, [String])] = [
        (.portrait, ["person", "people", "portrait", "human", "face", "adult", "man", "woman",
                     "child", "baby", "selfie", "bride", "groom", "teenager", "senior",
                     "male", "female"]),
        (.night,    ["night", "star", "moon", "firework", "candle", "neon", "dusk", "aurora"]),
        (.snow,     ["snow", "ice", "winter", "glacier", "frost", "ski", "blizzard"]),
        (.food,     ["food", "dish", "meal", "cuisine", "fruit", "vegetable", "cake", "dessert",
                     "drink", "coffee", "bread", "sushi", "pasta", "salad", "wine", "beverage"]),
        (.document, ["text", "document", "screenshot", "paper", "receipt", "menu", "chart",
                     "diagram", "whiteboard", "poster", "book", "letter", "newspaper"]),
        // 「风光」是兜底的自然/户外类：关键词铺得宽，但权重压低（见 sceneWeight），
        // 免得它靠数量压过题材更明确的几类。
        (.landscape, ["sky", "cloud", "sunset", "sunrise", "dawn", "horizon", "sunlight",
                      "tree", "plant", "flower", "grass", "leaf", "forest", "garden",
                      "vegetation", "foliage", "moss", "fern", "bush", "shrub", "blossom",
                      "beach", "ocean", "sea", "coast", "lake", "river", "waterfall",
                      "shore", "wave", "harbor", "pier", "water", "stream", "pond",
                      "mountain", "valley", "canyon", "hill", "desert", "landscape", "field",
                      "meadow", "cliff", "volcano", "dune", "prairie", "rock", "stone",
                      "building", "architecture", "skyscraper", "city", "street", "urban",
                      "bridge", "tower", "downtown", "construction", "house",
                      "animal", "cat", "dog", "bird", "wildlife", "pet", "insect",
                      "horse", "fish", "butterfly", "reptile"]),
    ]

    /// 场景权重：题材明确的几类要高过「风光」这个兜底，
    /// 否则一张人像只要背景里有点植物就会被判成风光。
    private static let sceneWeight: [PhotoScene: Double] = [
        .portrait: 1.7, .night: 1.6, .snow: 1.8, .food: 1.6, .document: 1.8, .landscape: 1.0,
    ]

    /// 给一张图分类。无副作用，可后台执行。
    static func classify(_ image: CIImage) -> SceneGuess {
        let extent = image.extent
        guard extent.width >= 32, extent.height >= 32 else { return SceneGuess() }

        let scale = min(1, sampleEdge / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = Engine.ctx.createCGImage(small, from: small.extent, format: .RGBA8,
                                                colorSpace: Engine.srgb) else { return SceneGuess() }

        let request = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        } catch {
            return SceneGuess()
        }
        guard let observations = request.results, !observations.isEmpty else { return SceneGuess() }

        let top = observations.prefix(topN)
        var scores: [PhotoScene: Double] = [:]
        // 命中该场景的标签里，最强的那一个的原始置信度
        var bestRaw: [PhotoScene: Double] = [:]
        // 越靠前的标签权重越高：第一名 1.0，第二十名约 0.3
        for (rank, obs) in top.enumerated() {
            let weight = 1.0 - Double(rank) / Double(topN + 4)
            let conf = Double(obs.confidence)
            let tokens = tokens(of: obs.identifier)
            for (scene, keys) in keywords where keys.contains(where: { matches(tokens, $0) }) {
                scores[scene, default: 0] += conf * weight * (sceneWeight[scene] ?? 1)
                bestRaw[scene] = max(bestRaw[scene] ?? 0, conf)
            }
        }

        var guess = SceneGuess()
        guess.top = observations.prefix(6).map { "\($0.identifier) \(Int($0.confidence * 100))%" }
        // 排序用得分（能反映「多个标签都指向同一题材」），
        // 但对外报的置信度用最强命中标签的原始值 —— 它才是可解释的那个数。
        if let best = scores.max(by: { $0.value < $1.value }) {
            let raw = bestRaw[best.key] ?? 0
            guess.confidence = raw
            guess.scene = raw >= minConfidence ? best.key : .other
        }
        return guess
    }

    // MARK: - 匹配

    /// 拆成小写单词，顺手去掉复数尾巴，避免 "trees" 匹配不上 "tree"
    private static func tokens(of identifier: String) -> [String] {
        identifier.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { raw in
                let t = String(raw)
                return t.count > 3 && t.hasSuffix("s") ? String(t.dropLast()) : t
            }
    }

    /// 短词要求完全相等（否则 "man" 会命中 "human"、"cat" 会命中 "caterpillar"），
    /// 长词允许前缀匹配（"cloud" 命中 "cloudy" / "cloudscape"）。
    private static func matches(_ tokens: [String], _ keyword: String) -> Bool {
        tokens.contains { token in
            if token == keyword { return true }
            return keyword.count >= 5 && token.hasPrefix(keyword)
        }
    }
}
