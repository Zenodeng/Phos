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
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 4 else { throw PhotoAIError(message:"Usage: photo-ai-data protocol|render input.json output-directory") }
            let command = CommandLine.arguments[1]
            let input = URL(fileURLWithPath:CommandLine.arguments[2])
            let out = URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
            try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
            let record = try JSONSerialization.jsonObject(with:Data(contentsOf:input)) as! [String:Any]
            let instruction = record["instruction"] as? String ?? ""
            if command == "protocol" {
                try json(PhotoAIService.editingSchema(instruction),to:out.appendingPathComponent("edit-schema.json"))
                let n = PhotoAIService.numericSchema(0,1,step:0.01)
                try json(["type":"object","properties":["x":n,"y":n,"width":n,"height":n],"required":["x","y","width","height"],"additionalProperties":false],to:out.appendingPathComponent("crop-schema.json"))
                try json(try object(EditParams()),to:out.appendingPathComponent("defaults.json"))
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
