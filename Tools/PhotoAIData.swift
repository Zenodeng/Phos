import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Offline dataset worker. Uses the production decoder, parameter language and renderer.
/// It never opens a workspace or writes an image sidecar.
@main struct PhotoAIData {
    static func json(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value))
    }
    static func png(_ image: CIImage, to url: URL) throws {
        guard let cg = Engine.ctx.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:Engine.srgb),
              let writer = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw PhotoAIError(message:"Cannot encode mask") }
        CGImageDestinationAddImage(writer,cg,nil)
        guard CGImageDestinationFinalize(writer) else { throw PhotoAIError(message:"Cannot save mask") }
    }
    /// Bounded global-only feasibility fit; targets never become automatic gold labels.
    static func fit(_ record: [String:Any], out: URL) throws {
        let started = Date()
        guard let sourcePath = record["inputImage"] as? String, let targetPath = record["targetImage"] as? String,
              let full = Engine.decode(URL(fileURLWithPath:sourcePath)), let target = Engine.decode(URL(fileURLWithPath:targetPath)) else { throw PhotoAIError(message:"Cannot decode fitting pair") }
        let aspect = full.extent.width/full.extent.height, targetAspect = target.extent.width/target.extent.height
        guard abs(aspect/targetAspect-1) < 0.025 else { throw PhotoAIError(message:"Pair requires alignment/crop; excluded from global fit") }
        let width = Int((192*min(1,aspect)).rounded()), height = Int((192*min(1,1/aspect)).rounded())
        func resized(_ image: CIImage) -> CIImage {
            image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY)).transformed(by:CGAffineTransform(scaleX:Double(width)/image.extent.width,y:Double(height)/image.extent.height))
        }
        let source = resized(full), reference = resized(target)
        func bytes(_ image: CIImage) -> [UInt8] {
            var pixels = [UInt8](repeating:0,count:width*height*4)
            Engine.ctx.render(image,toBitmap:&pixels,rowBytes:width*4,bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBA8,colorSpace:Engine.srgb)
            return pixels
        }
        let desired = bytes(reference)
        var evaluations = 0
        func error(_ params: EditParams) -> Double {
            evaluations += 1
            let actual = bytes(Engine.render(source,params))
            var total = 0.0
            for i in stride(from:0,to:actual.count,by:4) { for c in 0..<3 { total += abs(Double(actual[i+c])-Double(desired[i+c]))/255 } }
            return total/Double(width*height*3)
        }
        let keys = ["exposure","contrast","highlights","shadows","temperature","saturation"]
        let fields = keys.map(ParameterDescriptor.named)
        let defaults = EditParams()
        func penalty(_ params: EditParams) -> Double {
            fields.reduce(0) { $0 + abs(params[keyPath:$1.keyPath]-$1.defaultValue)/($1.range.upperBound-$1.range.lowerBound) } * 0.002
        }
        var best = defaults
        let baseline = error(best)
        var bestScore = baseline
        let limit = min(300,max(20,record["maxEvaluations"] as? Int ?? 180))
        for round in 0..<3 {
            for field in fields {
                let center = best[keyPath:field.keyPath]
                let step = (field.id == "exposure" ? 0.5 : 15.0)/pow(2,Double(round))
                for offset in [-2.0,-1,1,2] where evaluations < limit {
                    var candidate = best
                    candidate[keyPath:field.keyPath] = min(field.range.upperBound,max(field.range.lowerBound,center+offset*step))
                    let score = error(candidate)+penalty(candidate)
                    if score < bestScore { best = candidate; bestScore = score }
                }
            }
        }
        let residual = error(best)
        let before = try PhotoAIEditor.preview(source:full,params:defaults), after = try PhotoAIEditor.preview(source:full,params:best)
        try before.1.write(to:out.appendingPathComponent("before.jpg")); try after.1.write(to:out.appendingPathComponent("after.jpg"))
        let targetPreview = try PhotoAIEditor.preview(source:target,params:defaults)
        try targetPreview.1.write(to:out.appendingPathComponent("target.jpg"))
        try json(try object(best),to:out.appendingPathComponent("fitted-params.json"))
        try json(["status":"fit-candidate","method":"bounded coordinate descent / sRGB RGB MAE + neutral-scaled penalty","fields":keys,"clut":"fixed off; candidate search deferred","evaluations":evaluations,"baselineMAE":baseline,"fittedMAE":residual,"seconds":Date().timeIntervalSince(started),"humanAestheticApproval":false,"trainingEligible":false,"searchResolution":[width,height],"sourceAspect":aspect,"targetAspect":targetAspect],to:out.appendingPathComponent("fit.json"))
    }
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 4 else { throw PhotoAIError(message:"Usage: photo-ai-data protocol|render input.json output-directory") }
            let command = CommandLine.arguments[1]
            let input = URL(fileURLWithPath:CommandLine.arguments[2])
            let out = URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
            try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
            let record = try JSONSerialization.jsonObject(with:Data(contentsOf:input)) as! [String:Any]
            let instruction = record["instruction"] as? String ?? ""
            if command == "fit" { try fit(record,out:out); return }
            if command == "protocol" {
                try json(PhotoAIService.editingSchema(instruction),to:out.appendingPathComponent("edit-schema.json"))
                let n = PhotoAIService.numericSchema(0,1,step:0.01)
                try json(["type":"object","properties":["x":n,"y":n,"width":n,"height":n],"required":["x","y","width","height"],"additionalProperties":false],to:out.appendingPathComponent("crop-schema.json"))
                try json(try object(EditParams()),to:out.appendingPathComponent("defaults.json"))
                let base = try record["baseParams"].map { try decode(EditParams.self,$0) } ?? EditParams()
                let prompt = record["task"] as? String == "crop" ? PhotoAIService.cropPrompt(instruction:instruction) : try PhotoAIService.editingPrompt(instruction:instruction,base:base)
                try Data(prompt.utf8).write(to:out.appendingPathComponent("prompt.txt"))
                let descriptors: [[String:Any]] = ParameterDescriptor.all.map { field in
                    ["name":field.id,"label":field.label,"group":field.group,"min":field.range.lowerBound,"max":field.range.upperBound,"neutral":field.defaultValue,"unit":field.unit.isEmpty ? "Phos native relative units" : field.unit,"step":field.step,"semantics":"absolute; omitted preserves current","aiGlobalWritable":PhotoAIPlan.keys[field.id] != nil,"aiLocalWritable":PhotoAIPlan.localKeys[field.id] != nil]
                }
                try json(["serializationVersion":PhotoAIService.serializationVersion,"decoderFingerprint":PhotoAIService.decoderFingerprint,"version":PhotoAIService.trainingProtocolVersion,"parameters":descriptors,"allDefaults":try object(EditParams()),"engineMaskKinds":MaskKind.allCases.map(\.rawValue),"aiMaskKinds":["linear","radial","luminanceRange","person","subject","foreground"],"unsupportedAIKinds":["brush","colorRange","depth"],"coordinates":["crop":"top-left CURRENT preview","mask":"bottom-left POST-CROP preview"],"temperatureUnit":"relative, not Kelvin","idempotency":"absolute globals replace; new masks append and are NOT retry-idempotent; operation deduplication is not implemented"],to:out.appendingPathComponent("parameter-registry.json"))
                return
            }
            guard command == "render", let path = record["inputImage"] as? String,
                  let source = Engine.decode(URL(fileURLWithPath:path)) else { throw PhotoAIError(message:"Invalid command or image") }
            let base = try record["baseParams"].map { try decode(EditParams.self,$0) } ?? EditParams()
            let before = try PhotoAIEditor.preview(source:source,params:base)
            try before.1.write(to:out.appendingPathComponent("before.jpg"))
            try json(try object(base),to:out.appendingPathComponent("before-params.json"))
            var working = base
            if let value = record["crop"] {
                working = try decode(PhotoAICrop.self,value).applying(to:base,imageSize:CGSize(width:before.0.width,height:before.0.height))
            }
            var normalizations = [String]()
            var directionError: String?
            var rawDirectionError: String?
            var plan: PhotoAIPlan?
            if let value = record["plan"] {
                let raw = try decode(PhotoAIPlan.self,value)
                let canonical = try raw.masks.map(PhotoAIPlan.canonical)
                for (i,pair) in zip(raw.masks,canonical).enumerated() {
                    if try JSONSerialization.data(withJSONObject:object(pair.0),options:.sortedKeys) != JSONSerialization.data(withJSONObject:object(pair.1),options:.sortedKeys) { normalizations.append("mask-\(i+1)") }
                }
                try PhotoAIService.validateRequested(raw,base:working,instruction:instruction)
                plan = raw
                let proposed = try raw.applying(to:working)
                var rawCandidate = proposed
                var index = working.masks.count
                for r in raw.masks {
                    let c = try PhotoAIPlan.canonical(r)
                    if c.adjustments.values.allSatisfy({ $0 == 0 }) { continue }
                    guard index < rawCandidate.masks.count else { break }
                    rawCandidate.masks[index].inverted = r.inverted ?? false
                    for (key,value) in r.adjustments { if let keyPath = PhotoAIPlan.localKeys[key] { rawCandidate.masks[index].adjust[keyPath:keyPath] = value } }
                    if let g = r.geometry {
                        rawCandidate.masks[index].lumLow = g["lumLow"] ?? rawCandidate.masks[index].lumLow
                        rawCandidate.masks[index].lumHigh = g["lumHigh"] ?? rawCandidate.masks[index].lumHigh
                    }
                    index += 1
                }
                do { try PhotoAIDirectionCheck.validate(source:source,base:working,proposed:rawCandidate,regions:raw.masks) } catch { rawDirectionError = error.localizedDescription }
                do { try PhotoAIDirectionCheck.validate(source:source,base:working,proposed:proposed,regions:raw.masks) } catch { directionError = error.localizedDescription }
                working = proposed
            }
            if let value = record["targetParams"] {
                guard plan == nil, record["crop"] == nil else { throw PhotoAIError(message:"targetParams cannot be combined with plan/crop") }
                working = try decode(EditParams.self,value)
            }
            let after = try PhotoAIEditor.preview(source:source,params:working)
            try after.1.write(to:out.appendingPathComponent("after.jpg"))
            try json(try object(working),to:out.appendingPathComponent("after-params.json"))
            let scale = min(1,1024/max(source.extent.width,source.extent.height))
            let small = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            let rendered = Engine.render(small,working)
            var masks = [String]()
            for (i,mask) in working.masks.enumerated() {
                if let image = Engine.maskImage(for:mask,extent:rendered.extent,analyzed:rendered) {
                    let filename = "mask-\(i+1).png"
                    try png(image,to:out.appendingPathComponent(filename)); masks.append(filename)
                }
            }
            var report: [String:Any] = ["status":"rendered","changed":working != base,"normalizations":normalizations,"masks":masks,"beforeSize":[before.0.width,before.0.height],"afterSize":[after.0.width,after.0.height],"renderer":"Phos Engine.render / sRGB / production 1024px preview","directionChecked":plan?.masks.contains(where:{$0.brightness == "brighten" || $0.brightness == "darken"}) ?? false]
            report["directionError"] = directionError
            report["rawDirectionError"] = rawDirectionError
            try json(report,to:out.appendingPathComponent("render.json"))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
        }
    }
}
