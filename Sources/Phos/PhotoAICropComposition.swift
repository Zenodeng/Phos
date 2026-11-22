import Foundation
import ImageIO
import Vision

/// Convert the model's suggested framing into an executable box in the current preview.
enum PhotoAICropComposition {
    static let full = PhotoAICrop(x:0,y:0,width:1,height:1)

    static func requestedAspect(_ instruction: String) -> Double? {
        let clauses = instruction.components(separatedBy:CharacterSet(charactersIn:"，,；;。\n"))
        var aspects = Set<Double>()
        for clause in clauses {
            let text = clause.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !["不要","不必","不需要","别"].contains(where:text.hasPrefix),
                  ["裁","版","画幅","构图","比例","封面","crop"].contains(where:text.localizedCaseInsensitiveContains) else { continue }
            let number = "(16|10|9|8|5|4|3|2|1|十六|十|九|八|五|四|三|二|一)"
            let pattern = "(?<![0-9])"+number+"\\s*[:：比/∶]\\s*"+number+"(?![0-9])"
            if let regex = try? NSRegularExpression(pattern:pattern),
               let match = regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),
               let left = Range(match.range(at:1),in:text), let right = Range(match.range(at:2),in:text) {
                let chinese = ["十六":16.0,"十":10,"九":9,"八":8,"五":5,"四":4,"三":3,"二":2,"一":1]
                guard let width = Double(text[left]) ?? chinese[String(text[left])],
                      let height = Double(text[right]) ?? chinese[String(text[right])] else { continue }
                let raw = width/height
                let ratio = (text.contains("竖") || text.contains("直式")) ? min(raw,1/raw) :
                            (text.contains("横") || text.contains("橫")) ? max(raw,1/raw) : raw
                if (0.4...2.5).contains(ratio) { aspects.insert(ratio) }
            } else if text.contains("正方形") || text.contains("方形裁切") {
                aspects.insert(1)
            }
        }
        return aspects.count == 1 ? aspects.first : nil
    }

    static func explicitlyRequestsFraming(_ instruction: String) -> Bool {
        if requestedAspect(instruction) != nil { return true }
        return instruction.components(separatedBy:CharacterSet(charactersIn:"，,；;。\n")).contains { clause in
            let text = clause.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !["不要","不必","不需要","不","别","避免","保留","保持"].contains(where:text.hasPrefix) else { return false }
            return text.range(of:"^(?:请|先|再|然后|适度|稍微|略微|重新|自动){0,4}(?:裁切|裁剪|裁去|裁掉|裁成|收紧构图)",options:.regularExpression) != nil
        }
    }

    static func previewSize(_ jpeg: Data) throws -> CGSize {
        guard let image = CGImageSourceCreateWithData(jpeg as CFData,nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw PhotoAIError(message:"无法读取裁切预览的尺寸。") }
        return CGSize(width:width,height:height)
    }

    static func protectedBounds(_ jpeg: Data) -> CGRect? {
        let handler = VNImageRequestHandler(data:jpeg,options:[:])
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let faces = VNDetectFaceRectanglesRequest()
        let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
        guard (try? handler.perform([humans,faces,objects])) != nil else { return nil }
        let people = (humans.results ?? []).filter { $0.confidence >= 0.60 }.map(\.boundingBox)
        let portraits = (faces.results ?? []).filter { $0.confidence >= 0.65 }.map(\.boundingBox)
        let salient = (objects.results?.first?.salientObjects ?? []).filter { $0.confidence >= 0.60 }.map(\.boundingBox)
        let anchors = people.isEmpty && portraits.isEmpty ? salient : people + portraits
        guard let first = anchors.first else { return nil }
        let union = anchors.dropFirst().reduce(first) { $0.union($1) }
        let padded = CGRect(x:union.minX,y:1-union.maxY,width:union.width,height:union.height).insetBy(dx:-0.025,dy:-0.025)
        let frame = padded.intersection(CGRect(x:0,y:0,width:1,height:1))
        return frame.isNull || frame.isEmpty ? nil : frame
    }

    static func compose(_ proposed: PhotoAICrop, size: CGSize, aspect: Double? = nil, protected: CGRect? = nil) throws -> PhotoAICrop {
        guard [proposed.x,proposed.y,proposed.width,proposed.height].allSatisfy(\.isFinite) else {
            throw PhotoAIError(message:"裁切坐标无效。")
        }
        let width: Double, height: Double
        if let aspect {
            guard size.width > 0, size.height > 0, (0.4...2.5).contains(aspect) else {
                throw PhotoAIError(message:"无法计算要求的裁切画幅。")
            }
            let normalized = aspect*size.height/size.width
            width = min(1,normalized)
            height = min(1,1/normalized)
        } else {
            width = proposed.width; height = proposed.height
            guard proposed.x >= 0, proposed.y >= 0, (0.35...1).contains(width), (0.35...1).contains(height),
                  width*height >= 0.4, proposed.x+width <= 1.080001, proposed.y+height <= 1.080001 else {
                throw PhotoAIError(message:"裁切范围无效或过于激进，请重试。")
            }
            if width >= 0.999999 && height >= 0.999999 { return full }
            guard protected != nil || width*height >= 0.82 else {
                throw PhotoAIError(message:"无法可靠定位主体，建议更保守的裁切。")
            }
        }
        let center = CGPoint(x:proposed.x+proposed.width/2,y:proposed.y+proposed.height/2)
        let target = aspect != nil ? (protected.map { CGPoint(x:$0.midX,y:$0.midY) } ?? center) : center
        let anchor = protected ?? CGRect(x:0.5,y:0.5,width:0,height:0)
        let minX = protected == nil ? 0 : max(0,anchor.maxX-width)
        let maxX = protected == nil ? 1-width : min(1-width,anchor.minX)
        let minY = protected == nil ? 0 : max(0,anchor.maxY-height)
        let maxY = protected == nil ? 1-height : min(1-height,anchor.minY)
        guard minX <= maxX+0.000001, minY <= maxY+0.000001 else {
            throw PhotoAIError(message:"当前裁切无法完整保留已识别的主体。")
        }
        var result = PhotoAICrop(x:min(maxX,max(minX,target.x-width/2)),y:min(maxY,max(minY,target.y-height/2)),width:width,height:height)
        result.confirmedAspect = aspect
        _ = try result.applying(to:EditParams(),imageSize:size)
        return result
    }
}
