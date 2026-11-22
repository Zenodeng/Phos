import Foundation

/// Restrictions for clearly scoped local requests. Open directions still use the full planner.
struct PhotoAILocalIntent: Hashable {
    let target: String
    let brightness: String
    let kinds: Set<String>

    private static let separators = CharacterSet(charactersIn:"，,；;。\n")
    private static let preservation = ["保持","保留","维持","不变","不动","照旧","原样"]

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of:pattern,options:.regularExpression) != nil
    }

    static func onlyLocal(_ instruction: String) -> Bool {
        let clauses = instruction.components(separatedBy:separators).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if clauses.contains(where:{ clause in
            ["只做局部","仅做局部","只作局部","仅作局部","只用蒙版","仅用蒙版"].contains(where:clause.hasPrefix)
        }) { return true }
        let localTarget = semantic(instruction) != nil || clauses.contains { clause in
            clause.contains("蒙版") && !["不要","不加","不使用","保持","保留"].contains(where:clause.hasPrefix)
        }
        if localTarget && clauses.contains(where:{ clause in
            matches("(?:保留|保持|维持)(?:全部|原有|现有|当前|所有|其它|其他){0,2}(?:全局|整体)(?:已有)?(?:设置|参数|调整|编辑)",in:clause) ||
            matches("(?:全局|整体)(?:原有|已有|现有|当前)?(?:设置|参数|调整|编辑).{0,6}(?:不变|不动|照旧|原样|禁止修改)",in:clause)
        }) { return true }
        if clauses.contains(where:{ matches("^(?:只|仅)(?:创建|用|使用|调整)[^，。]{0,10}蒙版",in:$0) }) &&
            clauses.contains(where:{ matches("(?:其他|其它)(?:所有|已有)?参数(?:全部|均)?(?:保持|保留)?(?:不变|不动|照旧)",in:$0) }) {
            return true
        }
        guard let first = clauses.first, (first.hasPrefix("只") || first.hasPrefix("仅")), semantic(first) != nil else { return false }
        return clauses.dropFirst().allSatisfy { clause in
            preservation.contains(where:clause.contains) && !matches("(?:提亮|压暗|增加|减少|降低|提高|调高|调低|改变|设置)",in:clause) ||
            ["不要裁切","不裁切","不要再裁切","不要旋转"].contains(where:clause.hasPrefix)
        }
    }

    static func semantic(_ instruction: String) -> Self? {
        let clauses = instruction.components(separatedBy:separators).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
            .filter { !["不要","避免","不必","不需要","别","保留","保持","维持"].contains(where:$0.hasPrefix) }
        let targets: [(String,String,Set<String>)] = [
            ("background","(?:背景|人物身后的区域)",["person","subject","foreground"]),
            ("subject","(?:人物|主体|前景)",["person","subject","foreground"]),
            ("highlights","(?:高光|亮区|亮部|最亮(?:的)?(?:区域|部分)?)",["luminanceRange"]),
            ("shadows","(?:阴影|暗区|暗部|最暗(?:的)?(?:区域|部分)?)",["luminanceRange"]),
        ]
        let verbs = [("brighten","(?:提亮|调亮|变亮|提高曝光|(?:自然|稍微|略微)?亮一点)"),
                     ("darken","(?:压暗|压住|调暗|变暗|降低曝光|(?:自然|稍微|略微)?暗一点)")]
        var found = Set<Self>()
        for (target,word,kinds) in targets {
            for (brightness,verb) in verbs {
                if clauses.contains(where:{ text in
                    matches(verb+"(?:的|画面中|画面里|画面|一些|一点|\\s){0,4}"+word,in:text) ||
                    matches(word+"(?:蒙版|区域|部分|自然|稍微|略微|适当|一点|再|的|\\s){0,4}"+verb,in:text)
                }) {
                    let person = kinds.contains("person") && instruction.contains("人物")
                    found.insert(Self(target:target,brightness:brightness,kinds:person ? ["person"] : kinds))
                }
            }
        }
        return found.count == 1 ? found.first : nil
    }

    @MainActor static func explicit(_ instruction: String) -> Self? {
        guard onlyLocal(instruction), let intent = semantic(instruction) else { return nil }
        let requested = PhotoAIService.requestedMaskKinds(instruction)
        return requested.isEmpty || !intent.kinds.isDisjoint(with:requested) ? intent : nil
    }

    func matches(_ region: PhotoAIPlan.Region) -> Bool {
        kinds.contains(region.kind) && region.target == target && region.brightness == brightness
    }

    func constraining(_ masks: [String:Any]) -> [String:Any] {
        guard (masks["maxItems"] as? Int) != 0,
              let schema = masks["items"] as? [String:Any] else { return masks }
        let variants = (schema["anyOf"] as? [[String:Any]]) ?? [schema]
        let valid: [[String:Any]] = variants.compactMap { item in
            guard var props = item["properties"] as? [String:Any],
                  let kind = props["kind"] as? [String:Any],
                  let options = kind["enum"] as? [String] else { return nil }
            let supported = options.filter(kinds.contains)
            guard !supported.isEmpty else { return nil }
            props["kind"] = ["type":"string","enum":supported]
            props["target"] = ["type":"string","enum":[target]]
            props["brightness"] = ["type":"string","enum":[brightness]]
            var constrained = item
            constrained["properties"] = props
            return constrained
        }
        guard !valid.isEmpty else { return masks }
        var result = masks
        result["items"] = valid.count == 1 ? valid[0] : ["anyOf":valid]
        result["minItems"] = 1
        result["maxItems"] = 1
        return result
    }
}
