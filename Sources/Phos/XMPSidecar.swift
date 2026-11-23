import Foundation

/// Adobe XMP 旁档双向互通（无外部实体，严防 XXE）。
/// 支持读写标准 `xmp:Rating`（含 `-1` 淘汰）、`xmpDM:good`（旗标）、`xmp:Label`、`dc:subject` 关键词
/// 以及 Camera Raw (`crs:`) 全量调色、HSL、分通道曲线、颜色分级、校准、颗粒、裁剪参数与 `.xmp` 预设导入。
enum XMPSidecar {
    struct XMPMetadata {
        var rating: Int = 0
        var picked: Bool = false
        var rejected: Bool = false
        var label: ColorLabel = .none
        var keywords: [String] = []
        var params: EditParams = EditParams()
        var hasEdits: Bool = false
        var presetName: String = ""
        var hasGoodAttr: Bool = false

        func toSidecar() -> Sidecar {
            let finalPicked = hasGoodAttr ? picked : (picked || (!rejected && rating >= 4))
            return Sidecar(params: params, rating: rating, picked: finalPicked,
                           snapshots: [], colorLabel: label, rejected: rejected, keywords: keywords)
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
        delegate.applyCropResult()
        return delegate.result
    }

    static func parsePreset(from url: URL) -> Preset? {
        guard let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024 else { return nil }
        let baseName = url.deletingPathExtension().lastPathComponent
        return parsePreset(data: data, fallbackName: baseName)
    }

    static func parsePreset(data: Data, fallbackName: String = "Preset") -> Preset? {
        guard let meta = parse(data: data), meta.hasEdits else { return nil }
        let trimmed = meta.presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String((trimmed.isEmpty ? fallbackName : trimmed).prefix(120))
        return Preset(name: title.isEmpty ? "Preset" : title, params: meta.params, builtin: false)
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
        let ratingVal = s.rejected ? -1 : s.rating

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

        func curveBlock(tag: String, curve: ToneCurve) -> String {
            guard !curve.isIdentity else { return "" }
            let pts = curve.points.map {
                "          <rdf:li>\(Int(($0[0] * 255).rounded())), \(Int(($0[1] * 255).rounded()))</rdf:li>"
            }.joined(separator: "\n")
            return """
                  <\(tag)>
                    <rdf:Seq>
            \(pts)
                    </rdf:Seq>
                  </\(tag)>
            """
        }
        let curvesXML = curveBlock(tag: "crs:ToneCurvePV2012", curve: p.curve)
            + curveBlock(tag: "crs:ToneCurvePV2012Red", curve: p.curveR)
            + curveBlock(tag: "crs:ToneCurvePV2012Green", curve: p.curveG)
            + curveBlock(tag: "crs:ToneCurvePV2012Blue", curve: p.curveB)

        let hslNames = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
        var extraAttrs: [String] = []
        for i in 0..<8 {
            let band = p.hsl[i]
            let n = hslNames[i]
            if band.hue != 0 { extraAttrs.append("crs:HueAdjustment\(n)=\"\(Int(band.hue.rounded()))\"") }
            if band.sat != 0 { extraAttrs.append("crs:SaturationAdjustment\(n)=\"\(Int(band.sat.rounded()))\"") }
            if band.lum != 0 { extraAttrs.append("crs:LuminanceAdjustment\(n)=\"\(Int(band.lum.rounded()))\"") }
        }
        if !p.gradeShadow.isNeutral {
            extraAttrs.append("crs:ColorGradeShadowHue=\"\(Int(p.gradeShadow.hue.rounded()))\"")
            extraAttrs.append("crs:ColorGradeShadowSat=\"\(Int(p.gradeShadow.sat.rounded()))\"")
            extraAttrs.append("crs:ColorGradeShadowLum=\"\(Int(p.gradeShadow.lum.rounded()))\"")
        }
        if !p.gradeMid.isNeutral {
            extraAttrs.append("crs:ColorGradeMidtoneHue=\"\(Int(p.gradeMid.hue.rounded()))\"")
            extraAttrs.append("crs:ColorGradeMidtoneSat=\"\(Int(p.gradeMid.sat.rounded()))\"")
            extraAttrs.append("crs:ColorGradeMidtoneLum=\"\(Int(p.gradeMid.lum.rounded()))\"")
        }
        if !p.gradeHigh.isNeutral {
            extraAttrs.append("crs:ColorGradeHighlightHue=\"\(Int(p.gradeHigh.hue.rounded()))\"")
            extraAttrs.append("crs:ColorGradeHighlightSat=\"\(Int(p.gradeHigh.sat.rounded()))\"")
            extraAttrs.append("crs:ColorGradeHighlightLum=\"\(Int(p.gradeHigh.lum.rounded()))\"")
        }
        if p.gradeBlend != 50 { extraAttrs.append("crs:ColorGradeBlending=\"\(Int(p.gradeBlend.rounded()))\"") }
        if p.gradeBalance != 0 { extraAttrs.append("crs:SplitToningBalance=\"\(Int(p.gradeBalance.rounded()))\"") }

        if p.calibShadowTint != 0 { extraAttrs.append("crs:ShadowTint=\"\(Int(p.calibShadowTint.rounded()))\"") }
        if !p.primRed.isNeutral {
            extraAttrs.append("crs:RedHue=\"\(Int(p.primRed.hue.rounded()))\"")
            extraAttrs.append("crs:RedSaturation=\"\(Int(p.primRed.sat.rounded()))\"")
        }
        if !p.primGreen.isNeutral {
            extraAttrs.append("crs:GreenHue=\"\(Int(p.primGreen.hue.rounded()))\"")
            extraAttrs.append("crs:GreenSaturation=\"\(Int(p.primGreen.sat.rounded()))\"")
        }
        if !p.primBlue.isNeutral {
            extraAttrs.append("crs:BlueHue=\"\(Int(p.primBlue.hue.rounded()))\"")
            extraAttrs.append("crs:BlueSaturation=\"\(Int(p.primBlue.sat.rounded()))\"")
        }

        if p.mono {
            extraAttrs.append("crs:GrayMixerRed=\"\(Int((p.monoRed * 100).rounded()))\"")
            extraAttrs.append("crs:GrayMixerGreen=\"\(Int((p.monoGreen * 100).rounded()))\"")
            extraAttrs.append("crs:GrayMixerBlue=\"\(Int((p.monoBlue * 100).rounded()))\"")
        }

        let hasCrop = p.cropX > 0.0005 || p.cropY > 0.0005 || p.cropW < 0.9995 || p.cropH < 0.9995 || abs(p.straighten) > 0.005
        if hasCrop {
            let left = min(max(p.cropX, 0), 1)
            let right = min(max(p.cropX + p.cropW, left), 1)
            let top = min(max(1.0 - (p.cropY + p.cropH), 0), 1)
            let bottom = min(max(1.0 - p.cropY, top), 1)
            extraAttrs.append("crs:HasCrop=\"True\"")
            extraAttrs.append("crs:CropLeft=\"\(fmt(left, decimals: 6))\"")
            extraAttrs.append("crs:CropTop=\"\(fmt(top, decimals: 6))\"")
            extraAttrs.append("crs:CropRight=\"\(fmt(right, decimals: 6))\"")
            extraAttrs.append("crs:CropBottom=\"\(fmt(bottom, decimals: 6))\"")
            if abs(p.straighten) > 0.005 {
                extraAttrs.append("crs:CropAngle=\"\(fmt(-p.straighten, decimals: 4))\"")
            }
        }

        let extraXML = extraAttrs.isEmpty ? "" : "\n       " + extraAttrs.joined(separator: "\n       ")
        let labelAttr = labelStr.isEmpty ? "" : "\n       xmp:Label=\"\(labelStr)\""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Phos">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
               xmlns:xmp="http://ns.adobe.com/xap/1.0/"
               xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
               xmlns:dc="http://purl.org/dc/elements/1.1/"
               xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
               xmp:CreatorTool="Phos"
               xmp:Rating="\(ratingVal)"
               xmpDM:good="\(s.picked ? "True" : "False")"\(labelAttr)
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
               crs:GrainSize="\(Int((p.grainSize * 100).rounded()))"
               crs:GrainFrequency="\(Int((p.grainRoughness * 100).rounded()))"
               crs:PostCropVignetteAmount="\(Int(p.vignette.rounded()))"
               crs:PostCropVignetteMidpoint="\(Int((p.vignetteStart * 100).rounded()))"
               crs:ConvertToGrayscale="\(p.mono ? "True" : "False")"\(extraXML)
               crs:HasSettings="True">
        \(subjectXML)\(curvesXML)    </rdf:Description>
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
        private var hasCropFlag: Bool? = nil
        private var cropLeft: Double? = nil
        private var cropRight: Double? = nil
        private var cropTop: Double? = nil
        private var cropBottom: Double? = nil

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            elementCount += 1
            if elementCount > 5000 || stack.count > 32 { rejected = true; parser.abortParsing(); return }
            stack.append(elementName)
            text = ""
            if elementName == "rdf:Description" || elementName == "Description" {
                applyAttributes(attributes)
            }
            if ["crs:ToneCurvePV2012", "crs:ToneCurvePV2012Red", "crs:ToneCurvePV2012Green", "crs:ToneCurvePV2012Blue"].contains(elementName) {
                curvePoints = []
            }
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
                } else if stack.contains("crs:Name") && elementName == "rdf:li" {
                    if result.presetName.isEmpty { result.presetName = trimmed }
                } else if (stack.contains("crs:ToneCurvePV2012") ||
                           stack.contains("crs:ToneCurvePV2012Red") ||
                           stack.contains("crs:ToneCurvePV2012Green") ||
                           stack.contains("crs:ToneCurvePV2012Blue")) && elementName == "rdf:li" {
                    let parts = trimmed.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if parts.count == 2 {
                        curvePoints.append([min(max(parts[0] / 255.0, 0), 1), min(max(parts[1] / 255.0, 0), 1)])
                    }
                } else {
                    applyPair(key: elementName, value: trimmed)
                }
            }
            if elementName == "crs:ToneCurvePV2012", curvePoints.count >= 2 {
                result.params.curve = ToneCurve(points: curvePoints); result.hasEdits = true
            } else if elementName == "crs:ToneCurvePV2012Red", curvePoints.count >= 2 {
                result.params.curveR = ToneCurve(points: curvePoints); result.hasEdits = true
            } else if elementName == "crs:ToneCurvePV2012Green", curvePoints.count >= 2 {
                result.params.curveG = ToneCurve(points: curvePoints); result.hasEdits = true
            } else if elementName == "crs:ToneCurvePV2012Blue", curvePoints.count >= 2 {
                result.params.curveB = ToneCurve(points: curvePoints); result.hasEdits = true
            }
            if !stack.isEmpty { stack.removeLast() }
            text = ""
        }

        func applyCropResult() {
            if hasCropFlag == false { return }
            if let l = cropLeft, let r = cropRight, let t = cropTop, let b = cropBottom,
               r > l + 0.02, b > t + 0.02 {
                let x = min(max(l, 0), 0.95)
                let w = min(max(r - x, 0.05), 1.0 - x)
                let topC = min(max(t, 0), 0.95)
                let botC = min(max(b, topC + 0.05), 1.0)
                let h = botC - topC
                let y = min(max(1.0 - botC, 0), 1.0 - h)
                result.params.cropX = x
                result.params.cropY = y
                result.params.cropW = w
                result.params.cropH = h
                result.hasEdits = true
            }
        }

        private func applyAttributes(_ attrs: [String: String]) {
            for (k, v) in attrs { applyPair(key: k, value: v) }
        }

        private func applyPair(key: String, value: String) {
            func num() -> Double? { Double(value).flatMap { $0.isFinite ? $0 : nil } }
            func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
            switch key {
            case "xmp:Rating":
                if let r = Int(value) {
                    if r < 0 {
                        result.rejected = true
                        result.rating = 0
                        result.picked = false
                    } else {
                        result.rejected = false
                        result.rating = min(max(r, 0), 5)
                    }
                }
            case "xmpDM:good":
                result.hasGoodAttr = true
                let low = value.lowercased()
                result.picked = (low == "true" || low == "1" || low == "yes")
            case "xmp:Label":
                switch value.lowercased() {
                case "red", "红色": result.label = .red
                case "yellow", "黄色": result.label = .yellow
                case "green", "绿色": result.label = .green
                case "blue", "蓝色": result.label = .blue
                case "purple", "紫色": result.label = .purple
                default: break
                }
            case "crs:Name":
                if result.presetName.isEmpty && !value.isEmpty { result.presetName = value }
            case "crs:IncrementalTemperature":
                if let v = num() { result.params.temperature = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:Temperature":
                if result.params.temperature == 0, let v = num(), v >= 2000, v <= 12000 {
                    result.params.temperature = clamp((6500 - v) / 25.0, -100, 100); result.hasEdits = true
                }
            case "crs:IncrementalTint", "crs:Tint":
                if let v = num() { result.params.tint = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:Exposure2012":
                if let v = num() { result.params.exposure = clamp(v, -5, 5); result.hasEdits = true }
            case "crs:Contrast2012":
                if let v = num() { result.params.contrast = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:Highlights2012":
                if let v = num() { result.params.highlights = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:Shadows2012":
                if let v = num() { result.params.shadows = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:Whites2012":
                if let v = num() { result.params.whites = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:Blacks2012":
                if let v = num() { result.params.blacks = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:Texture":
                if let v = num() { result.params.texture = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:Clarity2012":
                if let v = num() { result.params.clarity = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:Dehaze":
                if let v = num() { result.params.dehaze = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:Vibrance":
                if let v = num() { result.params.vibrance = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:Saturation":
                if let v = num() { result.params.saturation = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:Sharpness":
                if let v = num() { result.params.sharpen = clamp(v / 50.0, 0, 2); result.hasEdits = true }
            case "crs:SharpenRadius":
                if let v = num() { result.params.sharpenRadius = clamp(v, 0.3, 3); result.hasEdits = true }
            case "crs:SharpenDetail":
                if let v = num() { result.params.sharpenDetail = clamp(v / 100.0, 0, 1); result.hasEdits = true }
            case "crs:SharpenEdgeMasking":
                if let v = num() { result.params.sharpenMask = clamp(v, 0, 100); result.hasEdits = true }
            case "crs:LuminanceSmoothing":
                if let v = num() { result.params.denoise = clamp(v, 0, 100); result.hasEdits = true }
            case "crs:ColorNoiseReduction":
                if let v = num() { result.params.denoiseColor = clamp(v, 0, 100); result.hasEdits = true }
            case "crs:GrainAmount":
                if let v = num() { result.params.grain = clamp(v, 0, 100); result.hasEdits = true }
            case "crs:GrainSize":
                if let v = num() { result.params.grainSize = clamp(v / 100.0, 0, 1); result.hasEdits = true }
            case "crs:GrainFrequency":
                if let v = num() { result.params.grainRoughness = clamp(v / 100.0, 0, 1); result.hasEdits = true }
            case "crs:PostCropVignetteAmount":
                if let v = num() { result.params.vignette = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:PostCropVignetteMidpoint":
                if let v = num() { result.params.vignetteStart = clamp(v / 100.0, 0, 1); result.hasEdits = true }
            case "crs:ConvertToGrayscale":
                result.params.mono = value.lowercased() == "true"
                if result.params.mono { result.hasEdits = true }
            case "crs:GrayMixerRed":
                if let v = num() { result.params.monoRed = clamp(v / 100.0, 0, 1); result.hasEdits = true }
            case "crs:GrayMixerGreen":
                if let v = num() { result.params.monoGreen = clamp(v / 100.0, 0, 1); result.hasEdits = true }
            case "crs:GrayMixerBlue":
                if let v = num() { result.params.monoBlue = clamp(v / 100.0, 0, 1); result.hasEdits = true }
            // 8 通道 HSL
            case "crs:HueAdjustmentRed":       if let v = num() { result.params.hsl.red.hue = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:HueAdjustmentOrange":    if let v = num() { result.params.hsl.orange.hue = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:HueAdjustmentYellow":    if let v = num() { result.params.hsl.yellow.hue = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:HueAdjustmentGreen":     if let v = num() { result.params.hsl.green.hue = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:HueAdjustmentAqua":      if let v = num() { result.params.hsl.aqua.hue = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:HueAdjustmentBlue":      if let v = num() { result.params.hsl.blue.hue = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:HueAdjustmentPurple":    if let v = num() { result.params.hsl.purple.hue = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:HueAdjustmentMagenta":   if let v = num() { result.params.hsl.magenta.hue = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:SaturationAdjustmentRed":     if let v = num() { result.params.hsl.red.sat = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:SaturationAdjustmentOrange":  if let v = num() { result.params.hsl.orange.sat = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:SaturationAdjustmentYellow":  if let v = num() { result.params.hsl.yellow.sat = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:SaturationAdjustmentGreen":   if let v = num() { result.params.hsl.green.sat = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:SaturationAdjustmentAqua":    if let v = num() { result.params.hsl.aqua.sat = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:SaturationAdjustmentBlue":    if let v = num() { result.params.hsl.blue.sat = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:SaturationAdjustmentPurple":  if let v = num() { result.params.hsl.purple.sat = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:SaturationAdjustmentMagenta": if let v = num() { result.params.hsl.magenta.sat = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:LuminanceAdjustmentRed":     if let v = num() { result.params.hsl.red.lum = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:LuminanceAdjustmentOrange":  if let v = num() { result.params.hsl.orange.lum = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:LuminanceAdjustmentYellow":  if let v = num() { result.params.hsl.yellow.lum = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:LuminanceAdjustmentGreen":   if let v = num() { result.params.hsl.green.lum = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:LuminanceAdjustmentAqua":    if let v = num() { result.params.hsl.aqua.lum = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:LuminanceAdjustmentBlue":    if let v = num() { result.params.hsl.blue.lum = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:LuminanceAdjustmentPurple":  if let v = num() { result.params.hsl.purple.lum = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:LuminanceAdjustmentMagenta": if let v = num() { result.params.hsl.magenta.lum = clamp(v, -100, 100); result.hasEdits = true }
            // 颜色分级
            case "crs:ColorGradeShadowHue", "crs:SplitToningShadowHue":
                if let v = num() { result.params.gradeShadow.hue = clamp(v, 0, 360); result.hasEdits = true }
            case "crs:ColorGradeShadowSat", "crs:SplitToningShadowSaturation":
                if let v = num() { result.params.gradeShadow.sat = clamp(v, 0, 100); result.hasEdits = true }
            case "crs:ColorGradeShadowLum":
                if let v = num() { result.params.gradeShadow.lum = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:ColorGradeMidtoneHue":
                if let v = num() { result.params.gradeMid.hue = clamp(v, 0, 360); result.hasEdits = true }
            case "crs:ColorGradeMidtoneSat":
                if let v = num() { result.params.gradeMid.sat = clamp(v, 0, 100); result.hasEdits = true }
            case "crs:ColorGradeMidtoneLum":
                if let v = num() { result.params.gradeMid.lum = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:ColorGradeHighlightHue", "crs:SplitToningHighlightHue":
                if let v = num() { result.params.gradeHigh.hue = clamp(v, 0, 360); result.hasEdits = true }
            case "crs:ColorGradeHighlightSat", "crs:SplitToningHighlightSaturation":
                if let v = num() { result.params.gradeHigh.sat = clamp(v, 0, 100); result.hasEdits = true }
            case "crs:ColorGradeHighlightLum":
                if let v = num() { result.params.gradeHigh.lum = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:ColorGradeBlending":
                if let v = num() { result.params.gradeBlend = clamp(v, 0, 100); result.hasEdits = true }
            case "crs:SplitToningBalance":
                if let v = num() { result.params.gradeBalance = clamp(v, -100, 100); result.hasEdits = true }
            // 相机校准
            case "crs:ShadowTint":
                if let v = num() { result.params.calibShadowTint = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:RedHue":
                if let v = num() { result.params.primRed.hue = clamp(v, -60, 60); result.hasEdits = true }
            case "crs:RedSaturation":
                if let v = num() { result.params.primRed.sat = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:GreenHue":
                if let v = num() { result.params.primGreen.hue = clamp(v, -60, 60); result.hasEdits = true }
            case "crs:GreenSaturation":
                if let v = num() { result.params.primGreen.sat = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:BlueHue":
                if let v = num() { result.params.primBlue.hue = clamp(v, -60, 60); result.hasEdits = true }
            case "crs:BlueSaturation":
                if let v = num() { result.params.primBlue.sat = clamp(v, -100, 100); result.hasEdits = true }
            // 裁剪与校直
            case "crs:HasCrop":
                hasCropFlag = value.lowercased() == "true"
            case "crs:CropLeft":
                if let v = num() { cropLeft = v }
            case "crs:CropRight":
                if let v = num() { cropRight = v }
            case "crs:CropTop":
                if let v = num() { cropTop = v }
            case "crs:CropBottom":
                if let v = num() { cropBottom = v }
            case "crs:CropAngle":
                if let v = num() { result.params.straighten = clamp(-v, -15, 15); result.hasEdits = true }
            default:
                break
            }
        }
    }
}
