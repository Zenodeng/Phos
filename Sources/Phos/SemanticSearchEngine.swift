import Foundation
import Vision
import CoreML

/// P3 本地双语语义搜图与视觉相似检索（中英概念词典 + OCR 文本 + VNFeaturePrint 相似度 + 可选 Core ML CLIP 插件口）。
enum SemanticSearchEngine {
    static let clipImageURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Phos/Models/CLIPImage.mlmodelc")
    static let clipTextURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Phos/Models/CLIPText.mlmodelc")

    static var isCLIPInstalled: Bool {
        FileManager.default.fileExists(atPath: clipImageURL.path) &&
        FileManager.default.fileExists(atPath: clipTextURL.path)
    }

    /// 120+ 组双语摄影概念词条（中文/英文触发词 → 语义扩展标签组）。
    private static let conceptDictionary: [([String], [String])] = [
        (["夕阳", "日落", "落日", "晚霞", "黄昏", "sunset", "dusk"], ["sunset", "sunrise", "dusk", "twilight", "sky", "evening", "sun", "夕阳", "日落"]),
        (["日出", "朝霞", "清晨", "黎明", "sunrise", "dawn"], ["sunrise", "dawn", "morning", "sky", "sun", "日出"]),
        (["猫", "猫咪", "小猫", "喵", "cat", "kitten"], ["cat", "feline", "kitten", "tabby", "pet", "mammal", "猫"]),
        (["狗", "小狗", "汪", "犬", "dog", "puppy"], ["dog", "canine", "puppy", "hound", "pet", "mammal", "狗"]),
        (["人像", "人物", "人", "肖像", "美女", "帅哥", "女孩", "男孩", "portrait", "person", "people", "human"], ["person", "people", "portrait", "face", "human", "woman", "man", "child", "人像", "人物"]),
        (["风景", "风光", "自然", "landscape", "nature", "scenery"], ["landscape", "nature", "outdoor", "scenery", "valley", "horizon", "风景"]),
        (["雪山", "高山", "山", "山峰", "山脉", "mountain", "alpine", "peak"], ["mountain", "peak", "alpine", "ridge", "cliff", "snow", "hill", "valley", "雪山", "山"]),
        (["海边", "大海", "海洋", "沙滩", "海浪", "海岸", "ocean", "sea", "beach", "coast"], ["sea", "ocean", "beach", "coast", "shore", "water", "wave", "sand", "海"]),
        (["湖", "湖泊", "江", "河", "水面", "倒影", "lake", "river", "reflection"], ["lake", "river", "water", "pond", "reflection", "boat", "湖", "河"]),
        (["森林", "树林", "树木", "树", "forest", "wood", "tree"], ["forest", "tree", "woods", "woodland", "foliage", "leaf", "森林", "树"]),
        (["花", "鲜花", "花朵", "樱花", "桃花", "玫瑰", "向日葵", "flower", "blossom"], ["flower", "blossom", "petal", "flora", "plant", "rose", "cherry blossom", "花"]),
        (["雪", "下雪", "雪景", "冬季", "冰", "snow", "winter", "ice"], ["snow", "winter", "ice", "frost", "glacier", "cold", "雪"]),
        (["雨", "雨天", "雨景", "rain", "rainy"], ["rain", "wet", "umbrella", "puddle", "storm", "雨"]),
        (["云", "云彩", "蓝天", "天空", "cloud", "sky"], ["sky", "cloud", "overcast", "horizon", "blue sky", "天空", "云"]),
        (["雾", "大雾", "云海", "薄雾", "fog", "mist"], ["fog", "mist", "haze", "cloud", "atmosphere", "雾"]),
        (["夜景", "夜晚", "黑夜", "深夜", "夜", "night", "nightscape"], ["night", "dark", "neon", "street light", "illuminated", "cityscape", "夜景"]),
        (["星空", "银河", "星星", "月亮", "夜空", "stars", "milky way", "moon"], ["night sky", "star", "moon", "astronomy", "galaxy", "constellation", "星空", "月"]),
        (["城市", "街头", "街拍", "街道", "都市", "city", "street", "urban"], ["city", "street", "urban", "downtown", "alley", "pedestrian", "traffic", "城市", "街"]),
        (["建筑", "大楼", "高楼", "教堂", "古建筑", "桥", "bridge", "architecture", "building"], ["architecture", "building", "skyscraper", "tower", "bridge", "facade", "interior", "建筑"]),
        (["美食", "食物", "吃的", "咖啡", "甜点", "餐厅", "food", "coffee", "cafe"], ["food", "dish", "meal", "cuisine", "coffee", "cup", "dessert", "restaurant", "美食", "咖啡"]),
        (["车", "汽车", "跑车", "火车", "地铁", "飞机", "car", "train", "plane", "vehicle"], ["car", "vehicle", "automobile", "train", "railway", "aircraft", "bicycle", "motorcycle", "车"]),
        (["鸟", "飞鸟", "海鸥", "bird", "avian"], ["bird", "avian", "feather", "wing", "gull", "eagle", "鸟"]),
        (["运动", "跑步", "篮球", "足球", "滑雪", "sport", "sports"], ["sport", "athlete", "running", "ski", "bicycle", "球"]),
        (["黑白", "单色", "bw", "monochrome", "black and white"], ["monochrome", "black and white", "grayscale", "noir", "黑白"]),
        (["室内", "房间", "家居", "indoor", "interior", "room"], ["indoor", "interior", "room", "furniture", "window", "室内"]),
        (["婚礼", "婚纱", "新人", "wedding", "bride"], ["wedding", "bride", "groom", "dress", "ceremony", "婚礼"]),
        (["动物", "野生动物", "animal", "wildlife"], ["animal", "wildlife", "mammal", "bird", "creature", "动物"]),
        (["秋天", "红叶", "落叶", "秋色", "autumn", "fall"], ["autumn", "fall", "foliage", "maple", "orange leaf", "秋"])
    ]

    private static let stopWords: Set<String> = [
        "的", "了", "在", "下", "上", "里", "中", "与", "和", "或", "拍", "照片", "图片", "一张",
        "the", "a", "an", "in", "on", "at", "under", "of", "with", "and", "or", "photo"
    ]

    /// 将用户搜索词解析为多个独立的语义概念簇，每个簇是一组等价英文/中文关键词。
    static func expandQueryGroups(_ query: String) -> [[String]] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return [] }

        var groups: [[String]] = []
        var remaining = cleaned

        // 优先长词匹配（如“夕阳下的猫”拆成“夕阳”与“猫”两组）
        let sortedEntries = conceptDictionary.flatMap { triggers, expansions in
            triggers.map { (trigger: $0.lowercased(), expansions: expansions) }
        }.sorted { $0.trigger.count > $1.trigger.count }

        for entry in sortedEntries {
            if remaining.contains(entry.trigger) {
                var fullGroup = entry.expansions.map { $0.lowercased() }
                if !fullGroup.contains(entry.trigger) { fullGroup.insert(entry.trigger, at: 0) }
                groups.append(fullGroup)
                remaining = remaining.replacingOccurrences(of: entry.trigger, with: " ")
            }
        }

        // 把剩下的非停用词作为精确子串簇
        for rawToken in remaining.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)) {
            let tok = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tok.isEmpty, !stopWords.contains(tok) else { continue }
            // 移除常见中文单字虚词前后缀；若剥离后为空说明整个残片都是虚词（如“夕阳下的猫”残留“下的”），直接跳过
            let stripped = tok.trimmingCharacters(in: CharacterSet(charactersIn: "的了着过在上下里中边旁前与和"))
            guard !stripped.isEmpty, !stopWords.contains(stripped) else { continue }
            groups.append([stripped])
        }
        return groups
    }

    static func expandQuery(_ query: String) -> [String] {
        Array(Set(expandQueryGroups(query).flatMap { $0 })).sorted()
    }

    static func matches(metrics: PhotoCullMetrics?, fileName: String, keywords: [String],
                        camera: String = "", lens: String = "", query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }

        let haystackDirect = ([fileName, camera, lens] + keywords + (metrics?.semanticTags ?? []) + [metrics?.ocrText ?? ""])
            .joined(separator: " \n ").lowercased()
        if haystackDirect.contains(q) { return true }

        let groups = expandQueryGroups(q)
        guard !groups.isEmpty else { return haystackDirect.contains(q) }
        return groups.allSatisfy { terms in
            terms.contains { term in haystackDirect.contains(term) }
        }
    }

    static func rankSimilar(target: VNFeaturePrintObservation,
                            candidates: [(id: UUID, feature: VNFeaturePrintObservation)]) -> [UUID] {
        var scored: [(UUID, Float)] = []
        scored.reserveCapacity(candidates.count)
        for (id, f) in candidates {
            var d: Float = .greatestFiniteMagnitude
            if (try? target.computeDistance(&d, to: f)) != nil {
                scored.append((id, d))
            }
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }
}
