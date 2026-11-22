import Foundation

/// Adobe XMP 旁档双向互通（无外部实体，严防 XXE）。
/// 支持读写标准 `xmp:Rating`、`xmp:Label`、`dc:subject` 关键词以及 Camera Raw (`crs:`) 基础影调参数。
enum XMPSidecar {
    struct XMPMetadata {
        var rating: Int = 0
        var label: ColorLabel = .none
        var keywords: [String] = []
        var params: EditParams = EditParams()
        var hasEdits: Bool = false

        func toSidecar() -> Sidecar {
            Sidecar(params: params, rating: rating, picked: rating >= 4,
                    snapshots: [], colorLabel: label, rejected: false, keywords: keywords)
        }
    }

    static func url(for imageURL: URL) -> URL {
        let withExt = imageURL.appendingPathExtension("xmp")
        if FileManager.default.fileExists(atPath: withExt.path) { return withExt }
        let base = imageURL.deletingPathExtension().appendingPathExtension("xmp")
        if FileManager.default.fileExists(atPath: base.path) { return base }
        return base
    }

    static func writeURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    static func read(for imageURL: URL) -> XMPMetadata? {
        let candidates = [
            imageURL.deletingPathExtension().appendingPathExtension("xmp"),
            imageURL.appendingPathExtension("xmp")
        ]
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: file), data.count <= 2 * 1024 * 1024 else { return nil }
        return parse(data: data)
    }

    static func parse(data: Data) -> XMPMetadata? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !text.uppercased().contains("<!ENTITY"),
              !text.uppercased().contains("<!DOCTYPE") else { return nil }
        let delegate = XMPParserDelegate()
        let parser = XMLParser(data: Data(text.utf8))
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.rejected else { return nil }
        return delegate.result
    }

    static func write(_ sidecar: Sidecar, for imageURL: URL) throws {
        #if PHOS_QA
        try QAWorkspace.scope.requireWritableImage(imageURL)
        #endif
        let dest = writeURL(for: imageURL)
        let xml = serialize(sidecar)
        try Data(xml.utf8).write(to: dest, options: .atomic)
    }

    static func serialize(_ s: Sidecar) -> String {
        let p = s.params
        func esc(_ str: String) -> String {
            str.replacingOccurrences(of: "&", with: "&amp;")
               .replacingOccurrences(of: "<", with: "&lt;")
               .replacingOccurrences(of: ">", with: "&gt;")
               .replacingOccurrences(of: "\"", with: "&quot;")
        }
        func fmt(_ v: Double, decimals: Int = 2) -> String {
            String(format: "%.\(decimals)f", v)
        }
        let labelStr: String
        switch s.colorLabel {
        case .none: labelStr = ""
        case .red: labelStr = "Red"
        case .yellow: labelStr = "Yellow"
        case .green: labelStr = "Green"
        case .blue: labelStr = "Blue"
        case .purple: labelStr = "Purple"
        }
        let crsTemp = Int((6500 - p.temperature * 25).rounded())
        let crsTint = Int(p.tint.rounded())
        let subjectXML: String
        if s.keywords.isEmpty {
            subjectXML = ""
        } else {
            let items = s.keywords.map { "          <rdf:li>\(esc($0))</rdf:li>" }.joined(separator: "\n")
            subjectXML = """
                  <dc:subject>
                    <rdf:Bag>
            \(items)
                    </rdf:Bag>
                  </dc:subject>
            """
        }
        var curveXML = ""
        if !p.curve.isIdentity {
            let pts = p.curve.points.map {
                "          <rdf:li>\(Int(($0[0] * 255).rounded())), \(Int(($0[1] * 255).rounded()))</rdf:li>"
            }.joined(separator: "\n")
            curveXML = """
                  <crs:ToneCurvePV2012>
                    <rdf:Seq>
            \(pts)
                    </rdf:Seq>
                  </crs:ToneCurvePV2012>
            """
        }
        let labelAttr = labelStr.isEmpty ? "" : "\n       xmp:Label=\"\(labelStr)\""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Phos">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
               xmlns:xmp="http://ns.adobe.com/xap/1.0/"
               xmlns:dc="http://purl.org/dc/elements/1.1/"
               xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
               xmp:CreatorTool="Phos"
               xmp:Rating="\(s.rating)"\(labelAttr)
               crs:Version="15.0"
               crs:ProcessVersion="11.0"
               crs:IncrementalTemperature="\(Int(p.temperature.rounded()))"
               crs:IncrementalTint="\(crsTint)"
               crs:Temperature="\(crsTemp)"
               crs:Tint="\(crsTint)"
               crs:Exposure2012="\(fmt(p.exposure))"
               crs:Contrast2012="\(Int(p.contrast.rounded()))"
               crs:Highlights2012="\(Int(p.highlights.rounded()))"
               crs:Shadows2012="\(Int(p.shadows.rounded()))"
               crs:Whites2012="\(Int(p.whites.rounded()))"
               crs:Blacks2012="\(Int(p.blacks.rounded()))"
               crs:Texture="\(Int(p.texture.rounded()))"
               crs:Clarity2012="\(Int(p.clarity.rounded()))"
               crs:Dehaze="\(Int(p.dehaze.rounded()))"
               crs:Vibrance="\(Int(p.vibrance.rounded()))"
               crs:Saturation="\(Int(p.saturation.rounded()))"
               crs:Sharpness="\(Int((p.sharpen * 50).rounded()))"
               crs:SharpenRadius="\(fmt(p.sharpenRadius))"
               crs:SharpenDetail="\(Int((p.sharpenDetail * 100).rounded()))"
               crs:SharpenEdgeMasking="\(Int(p.sharpenMask.rounded()))"
               crs:LuminanceSmoothing="\(Int(p.denoise.rounded()))"
               crs:ColorNoiseReduction="\(Int(p.denoiseColor.rounded()))"
               crs:GrainAmount="\(Int(p.grain.rounded()))"
               crs:PostCropVignetteAmount="\(Int(p.vignette.rounded()))"
               crs:ConvertToGrayscale="\(p.mono ? "True" : "False")"
               crs:HasSettings="True">
        \(subjectXML)\(curveXML)    </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
    }

    private final class XMPParserDelegate: NSObject, XMLParserDelegate {
        var result = XMPMetadata()
        var rejected = false
        private var stack: [String] = []
        private var text = ""
        private var curvePoints: [[Double]] = []
        private var elementCount = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            elementCount += 1
            if elementCount > 5000 || stack.count > 32 { rejected = true; parser.abortParsing(); return }
            stack.append(elementName)
            text = ""
            if elementName == "rdf:Description" || elementName == "Description" {
                applyAttributes(attributes)
            }
            if elementName == "crs:ToneCurvePV2012" { curvePoints = [] }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
            if text.count > 8192 { rejected = true; parser.abortParsing() }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if stack.contains("dc:subject") && elementName == "rdf:li" {
                    if !result.keywords.contains(trimmed) { result.keywords.append(trimmed) }
                } else if stack.contains("crs:ToneCurvePV2012") && elementName == "rdf:li" {
                    let parts = trimmed.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if parts.count == 2 {
                        curvePoints.append([min(max(parts[0] / 255.0, 0), 1), min(max(parts[1] / 255.0, 0), 1)])
                    }
                } else {
                    applyPair(key: elementName, value: trimmed)
                }
            }
            if elementName == "crs:ToneCurvePV2012", curvePoints.count >= 2 {
                result.params.curve = ToneCurve(points: curvePoints)
                result.hasEdits = true
            }
            if !stack.isEmpty { stack.removeLast() }
            text = ""
        }

        private func applyAttributes(_ attrs: [String: String]) {
            for (k, v) in attrs { applyPair(key: k, value: v) }
        }

        private func applyPair(key: String, value: String) {
            func num() -> Double? { Double(value).flatMap { $0.isFinite ? $0 : nil } }
            switch key {
            case "xmp:Rating":
                if let r = Int(value) { result.rating = min(max(r, 0), 5) }
            case "xmp:Label":
                switch value.lowercased() {
                case "red", "红色": result.label = .red
                case "yellow", "黄色": result.label = .yellow
                case "green", "绿色": result.label = .green
                case "blue", "蓝色": result.label = .blue
                case "purple", "紫色": result.label = .purple
                default: break
                }
            case "crs:IncrementalTemperature":
                if let v = num() { result.params.temperature = min(max(v, -100), 100); result.hasEdits = true }
            case "crs:Temperature":
                if result.params.temperature == 0, let v = num(), v >= 2000, v <= 12000 {
                    result.params.temperature = min(max((6500 - v) / 25.0, -100), 100); result.hasEdits = true
                }
            case "crs:IncrementalTint", "crs:Tint":
                if let v = num() { result.params.tint = min(max(v, -100), 100); result.hasEdits = true }
            case "crs:Exposure2012":
                if let v = num() { result.params.exposure = min(max(v, -5), 5); result.hasEdits = true }
            case "crs:Contrast2012":
                if let v = num() { result.params.contrast = min(max(v, -100), 100); result.hasEdits = true }
            case "crs:Highlights2012":
                if let v = num() { result.params.highlights = min(max(v, -100), 100); result.hasEdits = true }
            case "crs:Shadows2012":
                if let v = num() { result.params.shadows = min(max(v, -100), 100); result.hasEdits = true }
            case "crs:Whites2012":
                if let v = num() { result.params.whites = min(max(v, -100), 100); result.hasEdits = true }
            case "crs:Blacks2012":
                if let v = num() { result.params.blacks = min(max(v, -100), 100); result.hasEdits = true }
            case "crs:Texture":
                if let v = num() { result.params.texture = min(max(v, -100), 100); result.hasEdits = true }
            case "crs:Clarity2012":
                if let v = num() { result.params.clarity = min(max(v, 0), 100); result.hasEdits = true }
            case "crs:Dehaze":
                if let v = num() { result.params.dehaze = min(max(v, -100), 100); result.hasEdits = true }
            case "crs:Vibrance":
                if let v = num() { result.params.vibrance = min(max(v, -100), 100); result.hasEdits = true }
            case "crs:Saturation":
                if let v = num() { result.params.saturation = min(max(v, -100), 100); result.hasEdits = true }
            case "crs:Sharpness":
                if let v = num() { result.params.sharpen = min(max(v / 50.0, 0), 2); result.hasEdits = true }
            case "crs:SharpenRadius":
                if let v = num() { result.params.sharpenRadius = min(max(v, 0.3), 3); result.hasEdits = true }
            case "crs:SharpenDetail":
                if let v = num() { result.params.sharpenDetail = min(max(v / 100.0, 0), 1); result.hasEdits = true }
            case "crs:SharpenEdgeMasking":
                if let v = num() { result.params.sharpenMask = min(max(v, 0), 100); result.hasEdits = true }
            case "crs:LuminanceSmoothing":
                if let v = num() { result.params.denoise = min(max(v, 0), 100); result.hasEdits = true }
            case "crs:ColorNoiseReduction":
                if let v = num() { result.params.denoiseColor = min(max(v, 0), 100); result.hasEdits = true }
            case "crs:GrainAmount":
                if let v = num() { result.params.grain = min(max(v, 0), 100); result.hasEdits = true }
            case "crs:PostCropVignetteAmount":
                if let v = num() { result.params.vignette = min(max(v, -100), 100); result.hasEdits = true }
            case "crs:ConvertToGrayscale":
                result.params.mono = value.lowercased() == "true"
                if result.params.mono { result.hasEdits = true }
            default:
                break
            }
        }
    }
}
