import Foundation
import CoreImage

struct PhotoAICrop: Codable {
    var x: Double
    var y: Double // top-left in the CURRENT displayed image, independent of engine coordinates
    var width: Double
    var height: Double
    /// Exact edge percentages need arithmetic, not a language-model estimate.
    static func explicit(_ instruction: String) throws -> Self? {
        let text = instruction.replacingOccurrences(of:"％",with:"%")
        if text.range(of:"(?:^|[，。；;\\s])(?:不要裁切|不裁切|保留原构图)(?:$|[，。；;\\s])",options:.regularExpression) != nil {
            return Self(x:0,y:0,width:1,height:1)
        }
        guard let regex = try? NSRegularExpression(pattern:"裁(?:去|掉)?(?:左右|左、右)(?:两侧|两边)?各\\s*([0-9]+(?:\\.[0-9]+)?)\\s*%"),
              let match = regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),
              let range = Range(match.range(at:1),in:text), let percentage = Double(text[range]) else { return nil }
        // Only this unambiguous full-height form is deterministic; other compositions use the model.
        guard text.contains("保留完整高度"), !text.contains("上下"), !text.replacingOccurrences(of:"不要旋转",with:"").replacingOccurrences(of:"不旋转",with:"").contains("旋转") else { return nil }
        let edge = percentage/100
        let crop = Self(x:edge,y:0,width:1-2*edge,height:1)
        _ = try crop.applying(to:EditParams())
        return crop
    }
    func applying(to base: EditParams, imageSize: CGSize = CGSize(width:1,height:1)) throws -> EditParams {
        guard [x,y,width,height].allSatisfy(\.isFinite), x >= 0, y >= 0,
              width >= 0.35, height >= 0.35, width*height >= 0.4,
              x+width <= 1.000001, y+height <= 1.000001 else { throw PhotoAIError(message:"裁切范围无效或过于激进，请重试。") }
        var p = base
        p.cropX = base.cropX + x*base.cropW
        p.cropY = base.cropY + (1-y-height)*base.cropH
        p.cropW = width*base.cropW; p.cropH = height*base.cropH
        let bottom = 1-y-height
        let radiusScale = Double(min(imageSize.width,imageSize.height)/min(imageSize.width*width,imageSize.height*height))
        func strokes(_ values: [Stroke]) -> [Stroke] {
            values.map { original in
                var stroke = original; stroke.pts = original.pts.map { point in [(point[0]-x)/width,(point[1]-bottom)/height] }
                stroke.radius *= radiusScale; return stroke
            }
        }
        for i in p.masks.indices {
            var m = p.masks[i]
            m.x0 = (m.x0-x)/width; m.x1 = (m.x1-x)/width
            m.y0 = (m.y0-bottom)/height; m.y1 = (m.y1-bottom)/height
            m.radius *= radiusScale
            if let rx = m.radiusX { m.radiusX = rx*radiusScale }; if let ry = m.radiusY { m.radiusY = ry*radiusScale }
            m.strokes = strokes(m.strokes); m.refinements = strokes(m.refinements)
            p.masks[i] = m
        }
        return p
    }
}

extension PhotoAIPlan {
    static let curveKeys: [String: WritableKeyPath<EditParams,ToneCurve>] = ["rgb": \.curve,"luma": \.lumaCurve,"red": \.curveR,"green": \.curveG,"blue": \.curveB]
    static let gradeKeys: [String: WritableKeyPath<EditParams,ColorGrade>] = ["shadows": \.gradeShadow,"midtones": \.gradeMid,"highlights": \.gradeHigh]
    static let bands = ["red","orange","yellow","green","aqua","blue","purple","magenta"]
    static let brightnessKeys: Set<String> = ["exposure","highlights","shadows","whites","blacks"]
    static func range(_ key: String, local: Bool) -> ClosedRange<Double> {
        if local { return key == "exposure" ? -4...4 : (key == "sharpen" || key == "denoise" || key == "clarity" ? 0...100 : -100...100) }
        return ParameterDescriptor.named(key).range
    }
    func advanced(to base: EditParams) throws -> EditParams {
        var p = base
        for (channel, points) in curves ?? [:] {
            guard let path = Self.curveKeys[channel], (2...9).contains(points.count),
                  points.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }),
                  points.first?[0] == 0, points.last?[0] == 1 else { throw PhotoAIError(message:"曲线控制点无效。") }
            for i in 1..<points.count { guard points[i][0]-points[i-1][0] >= 0.006, points[i][1] >= points[i-1][1] else { throw PhotoAIError(message:"曲线必须按横坐标递增，且不能反转影调。") } }
            p[keyPath:path] = ToneCurve(points:points)
        }
        for (band, values) in hsl ?? [:] {
            guard let i = Self.bands.firstIndex(of:band), Set(values.keys).isSubset(of:["hue","sat","lum"]) else { throw PhotoAIError(message:"不支持的 HSL 分区。") }
            var b = p.hsl[i]
            for (key,value) in values {
                guard value.isFinite, (key == "hue" ? -60.0...60.0 : -100.0...100.0).contains(value) else { throw PhotoAIError(message:"HSL 数值超出范围。") }
                switch key { case "hue": b.hue = value; case "sat": b.sat = value; default: b.lum = value }
            }
            p.hsl[i] = b
        }
        for (band,values) in grading ?? [:] {
            guard let path = Self.gradeKeys[band], Set(values.keys).isSubset(of:["hue","sat","lum"]) else { throw PhotoAIError(message:"不支持的颜色分级。") }
            var g = p[keyPath:path]
            for (key,value) in values {
                let range: ClosedRange<Double> = key == "hue" ? 0...360 : (key == "sat" ? 0...100 : -100...100)
                guard value.isFinite, range.contains(value) else { throw PhotoAIError(message:"颜色分级数值超出范围。") }
                switch key { case "hue": g.hue = value; case "sat": g.sat = value; default: g.lum = value }
            }
            p[keyPath:path] = g
        }
        return p
    }
    /// Separate selection from tonal intent. White mask pixels receive the local adjustment.
    static func canonical(_ input: Region) throws -> Region {
        var r = input
        guard r.target == nil || ["subject","background","highlights","shadows","region"].contains(r.target!) else { throw PhotoAIError(message:"蒙版目标无效。") }
        guard r.brightness == nil || ["brighten","darken","unchanged"].contains(r.brightness!) else { throw PhotoAIError(message:"蒙版明暗意图无效。") }
        if r.target == "subject" || r.target == "background" {
            guard ["person","subject","foreground"].contains(r.kind) else { throw PhotoAIError(message:"主体或背景需要语义蒙版。") }
            r.inverted = r.target == "background"
        }
        if r.target == "highlights" || r.target == "shadows" {
            guard r.kind == "luminanceRange" else { throw PhotoAIError(message:"亮区或暗部需要亮度范围蒙版。") }
            r.inverted = false
            r.geometry = ["lumLow": r.target == "highlights" ? 0.65 : 0, "lumHigh": r.target == "highlights" ? 1 : 0.35, "lumSoft":0.15]
        }
        if let intent = r.brightness {
            for (key,value) in r.adjustments where brightnessKeys.contains(key) {
                if intent == "unchanged", value != 0 { throw PhotoAIError(message:"蒙版声称不改变明暗，却返回了影调修改。") }
                if intent == "brighten" { r.adjustments[key] = abs(value) }
                if intent == "darken" { r.adjustments[key] = -abs(value) }
            }
        }
        return r
    }
    func enforcing(_ instruction: String) throws -> Self {
        var result = self
        let mappings = [("subject",["主体","人物"]),("background",["背景"]),("highlights",["亮区","高光"]),("shadows",["暗部","阴影"])]
        for i in result.masks.indices {
            var r = result.masks[i]
            if let words = mappings.first(where: { $0.0 == r.target })?.1 {
                var intents = Set<String>()
                for word in words {
                    for (intent,verbs) in [("brighten",["提亮","变亮","提高曝光"]),("darken",["压暗","变暗","降低曝光"])] {
                        for verb in verbs {
                            for pattern in [word+".{0,6}?"+verb,verb+"(?:的|\\s)*"+word] {
                                if instruction.range(of:pattern,options:.regularExpression) != nil { intents.insert(intent) }
                            }
                        }
                    }
                }
                if intents.count == 1 { r.brightness = intents.first }
            }
            result.masks[i] = try Self.canonical(r)
        }
        return result
    }
    var detail: String {
        var parts = [String]()
        if let curves, !curves.isEmpty { parts.append("曲线 \(curves.keys.sorted().joined(separator:"、"))") }
        if let hsl, !hsl.isEmpty { parts.append("HSL \(hsl.keys.sorted().joined(separator:"、"))") }
        if let grading, !grading.isEmpty { parts.append("颜色分级 \(grading.keys.sorted().joined(separator:"、"))") }
        for r in masks {
            let sign = r.brightness == "brighten" ? "提亮" : (r.brightness == "darken" ? "压暗" : "调整")
            let target = ["subject":"主体","background":"背景","highlights":"亮区","shadows":"暗部","region":"选区"][r.target ?? "region"] ?? "选区"
            parts.append("\(target)\(sign)")
        }
        return parts.joined(separator:" · ")
    }
}

/// Verify the rendered, selected region, rather than trusting the model's explanation.
enum PhotoAIDirectionCheck {
    static func validate(source: CIImage, base: EditParams, proposed: EditParams, regions: [PhotoAIPlan.Region]) throws {
        let scale = min(1,512/max(source.extent.width,source.extent.height))
        let small = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        var prefix = proposed; prefix.masks = base.masks
        for (index,region) in regions.enumerated() {
            let canonical = try PhotoAIPlan.canonical(region)
            if canonical.adjustments.values.allSatisfy({ $0 == 0 }) { continue }
            guard prefix.masks.count < proposed.masks.count else { throw PhotoAIError(message:"局部调整记录不一致。") }
            let mask = proposed.masks[prefix.masks.count]
            let before = Engine.render(small,prefix)
            guard let weights = Engine.maskImage(for:mask,extent:before.extent,analyzed:before) else { throw PhotoAIError(message:"无法识别第 \(index+1) 个蒙版目标。") }
            let coverage = mean(weights)[0]
            guard coverage > 0.003 else { throw PhotoAIError(message:"未能选中“\(mask.name)”的目标，请换一种蒙版要求。") }
            prefix.masks.append(mask)
            guard let intent = canonical.brightness, intent != "unchanged" else { continue }
            let after = Engine.render(small,prefix)
            let a = mean(before.applyingFilter("CIMultiplyCompositing",parameters:[kCIInputBackgroundImageKey:weights]))
            let b = mean(after.applyingFilter("CIMultiplyCompositing",parameters:[kCIInputBackgroundImageKey:weights]))
            let delta = (0.2126*(b[0]-a[0])+0.7152*(b[1]-a[1])+0.0722*(b[2]-a[2]))/coverage
            guard intent == "brighten" ? delta > 0.00005 : delta < -0.00005 else { throw PhotoAIError(message:"“\(mask.name)”的实际明暗变化与要求不符，已拦截该建议。") }
        }
    }
    private static func mean(_ image: CIImage) -> [Float] {
        let averaged = image.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:image.extent)])
        var pixel = [Float](repeating:0,count:4)
        Engine.ctx.render(averaged,toBitmap:&pixel,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:Engine.srgb)
        return pixel
    }
}

extension PhotoAIService {
    static func validateRequested(_ plan: PhotoAIPlan, base: EditParams, instruction: String) throws {
        let protected = preservedGlobalKeys(instruction)
        guard Set(plan.adjustments.keys).isDisjoint(with:protected) else {
            throw PhotoAIError(message:"用户要求保留全局参数，请删除对应的全局调整，仅调整指定蒙版。")
        }
        let candidate = try plan.applying(to:base)
        let curveClauses = instruction.components(separatedBy:CharacterSet(charactersIn:"，,；;。\n")).filter { $0.contains("曲线") }
        let curveRequest = curveClauses.joined(separator:" ")
        let keepCurve = curveRequest.contains("保持") || curveRequest.contains("保留") || curveRequest.contains("不改变") || curveRequest.contains("不调整")
        if !keepCurve, ["提","压","抬","增强","增加","改变","调整"].contains(where:curveRequest.contains) {
            let paths = curveRequest.contains("亮度曲线") ? [\EditParams.lumaCurve] : Array(PhotoAIPlan.curveKeys.values)
            let changed = paths.contains { candidate[keyPath:$0] != base[keyPath:$0] }
            guard changed else { throw PhotoAIError(message:"用户要求改变曲线，但曲线完全未变。请实际修改控制点，例如提亮中间调可把(0.5,0.5)改为(0.5,0.54)。") }
        }
        if instruction.localizedCaseInsensitiveContains("HSL"), instruction.contains("降低"), candidate.hsl == base.hsl {
            throw PhotoAIError(message:"用户要求用HSL降低饱和度，但HSL数值未变，请修改对应颜色分区。")
        }
    }
    /// Restrict only explicit preservation requests; mixed global/local instructions remain supported.
    static func preservedGlobalKeys(_ instruction: String) -> Set<String> {
        let clauses = instruction.components(separatedBy:CharacterSet(charactersIn:"；;。\n"))
        let preserving = clauses.filter { clause in
            ["保持不变","保留不变","不要改变","不要修改","不调整","不改动"].contains(where:clause.contains)
        }
        if preserving.contains(where: { $0.contains("全局参数") || $0.contains("所有全局") || $0.contains("整体参数") }) {
            return Set(PhotoAIPlan.keys.keys)
        }
        let explicitGlobalChange = instruction.range(of:"(?:全局|整体)(?:曝光|对比度|饱和度|色温|参数)[^，。；;\\n]{0,8}(?:设置|设为|提高|降低|增加|减少|提亮|压暗)",options:.regularExpression) != nil
        if !explicitGlobalChange, instruction.contains("蒙版"), preserving.contains(where: { $0.contains("其他参数保持不变") || $0.contains("其他参数均保持不变") }) {
            return Set(PhotoAIPlan.keys.keys)
        }
        var keys = Set<String>()
        for clause in preserving {
            if clause.contains("全局曝光") || clause.contains("整体曝光") { keys.insert("exposure") }
            if clause.contains("白平衡") { keys.formUnion(["temperature","tint"]) }
        }
        return keys
    }
    /// Explicitly requested tools must be emitted, not silently replaced by basic exposure.
    static func editingSchema(_ instruction: String) -> [String:Any] {
        var result = schema(for:instruction)
        var properties = result["properties"] as! [String:Any]
        var required = result["required"] as! [String]
        func forbid(_ tool: String) -> Bool {
            instruction.range(of:"(?:不要|不使用|禁用|保持|保留|不改变)[^，。；;\\n]{0,5}"+tool,options:[.regularExpression,.caseInsensitive]) != nil
        }
        func require(_ key: String, fields: [String]) {
            guard var object = properties[key] as? [String:Any] else { return }
            required.append(key); object["minProperties"] = 1
            if !fields.isEmpty { object["required"] = fields }
            properties[key] = object
        }
        if instruction.localizedCaseInsensitiveContains("HSL"), !forbid("HSL") {
            let colors = [("red","红色"),("orange","橙色"),("yellow","黄色"),("green","绿色"),("aqua","青色"),("blue","蓝色"),("purple","紫色"),("magenta","洋红")]
            let clause = instruction.components(separatedBy:CharacterSet(charactersIn:"；;。\n")).filter { $0.localizedCaseInsensitiveContains("HSL") }.joined(separator:" ")
            require("hsl",fields:colors.filter { clause.contains($0.1) }.map(\.0))
        }
        if instruction.contains("曲线"), !forbid("曲线") { require("curves",fields:instruction.contains("亮度曲线") ? ["luma"] : []) }
        if instruction.contains("分级"), !forbid("分级") {
            let bands = [("shadows","阴影"),("midtones","中间调"),("highlights","高光")]
            let selected = bands.filter { instruction.range(of:$0.1+".{0,4}分级",options:.regularExpression) != nil }.map(\.0)
            require("grading",fields:selected)
            if var object = properties["grading"] as? [String:Any], var fields = object["properties"] as? [String:Any] {
                for band in selected { if var value = fields[band] as? [String:Any] { value["required"] = ["hue","sat"]; fields[band] = value } }
                object["properties"] = fields; properties["grading"] = object
            }
        }
        if instruction.contains("不要新增蒙版") || instruction.contains("不加蒙版") {
            var masks = properties["masks"] as! [String:Any]; masks["maxItems"] = 0; properties["masks"] = masks
        }
        for (key,word) in [("hsl","HSL"),("curves","曲线"),("grading","分级")] where forbid(word) {
            properties.removeValue(forKey:key); required.removeAll { $0 == key }
        }
        if var globals = properties["adjustments"] as? [String:Any], var fields = globals["properties"] as? [String:Any] {
            for key in preservedGlobalKeys(instruction) { fields.removeValue(forKey:key) }
            globals["properties"] = fields; properties["adjustments"] = globals
        }
        result["properties"] = properties; result["required"] = required
        return result
    }
}
