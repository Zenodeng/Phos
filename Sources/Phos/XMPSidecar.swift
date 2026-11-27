import Foundation

/// Adobe XMP 旁档双向互通（无外部实体，严防 XXE）。
/// 支持读写标准 `xmp:Rating`（含 `-1` 淘汰）、`xmpDM:good`（旗标）、`xmp:Label`、`dc:subject` 关键词、
/// Camera Raw (`crs:`) 全量调色、HSL、分通道曲线、颜色分级、校准、颗粒、裁剪、透视/参考线、相机配置文件、
/// 以及 Lightroom Classic / ACR 现代 `<crs:MaskGroupBasedCorrections>` 局部蒙版（含布尔加/减/交子蒙版与全部局部滑杆）。
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
              let data = try? Data(contentsOf: file), data.count <= 4 * 1024 * 1024 else { return nil }
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
        guard let data = try? Data(contentsOf: url), data.count <= 4 * 1024 * 1024 else { return nil }
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

        if !p.cameraProfileName.isEmpty {
            extraAttrs.append("crs:CameraProfile=\"\(esc(p.cameraProfileName))\"")
        }

        // 透视与 Guided Upright 参考线（兼容 Lightroom crs:UprightFourSegments）
        if p.perspectiveV != 0 { extraAttrs.append("crs:PerspectiveVertical=\"\(Int(p.perspectiveV.rounded()))\"") }
        if p.perspectiveH != 0 { extraAttrs.append("crs:PerspectiveHorizontal=\"\(Int(p.perspectiveH.rounded()))\"") }
        if p.uprightGuides.count >= 2 {
            extraAttrs.append("crs:PerspectiveUpright=\"5\"")
            extraAttrs.append("crs:UprightFourSegmentsCount=\"\(min(p.uprightGuides.count, 4))\"")
            for (i, g) in p.uprightGuides.prefix(4).enumerated() {
                // LR 坐标系 Y 向下：y_lr = 1 - y_phos
                let seg = "\(fmt(g.x0, decimals: 6)),\(fmt(1.0 - g.y0, decimals: 6)),\(fmt(g.x1, decimals: 6)),\(fmt(1.0 - g.y1, decimals: 6))"
                extraAttrs.append("crs:UprightFourSegments\(i)=\"\(seg)\"")
            }
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

        // Lightroom Classic / ACR 现代局部蒙版序列化（<crs:MaskGroupBasedCorrections>）
        let masksXML = serializeMasks(p.masks, esc: esc, fmt: fmt)

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
               crs:Version="16.0"
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
        \(subjectXML)\(curvesXML)\(masksXML)    </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
    }

    // MARK: - 蒙版 XMP 序列化（ACR / Lightroom MaskGroupBasedCorrections）

    private static func serializeMasks(
        _ masks: [Mask],
        esc: (String) -> String,
        fmt: (Double, Int) -> String
    ) -> String {
        let exportable = masks.filter { $0.kind != .depth }
        guard !exportable.isEmpty else { return "" }

        var groupEntries: [String] = []
        for m in exportable {
            let a = m.adjust
            var corrAttrs: [String] = [
                "crs:What=\"Correction\"",
                "crs:CorrectionAmount=\"1\"",
                "crs:CorrectionActive=\"\(m.enabled ? "true" : "false")\"",
                "crs:CorrectionName=\"\(esc(m.name.isEmpty ? m.kind.label : m.name))\"",
                "crs:CorrectionSyncID=\"\(m.id.uuidString.replacingOccurrences(of: "-", with: ""))\""
            ]
            // ACR 局部滑杆归一化范围约定：Exposure 为 EV/4 或直接 EV，其余 -1..1（100 -> 1.0）
            if abs(a.exposure) > 1e-4    { corrAttrs.append("crs:LocalExposure2012=\"\(fmt(a.exposure / 4.0, 4))\"") }
            if abs(a.contrast) > 1e-4    { corrAttrs.append("crs:LocalContrast2012=\"\(fmt(a.contrast / 100.0, 4))\"") }
            if abs(a.highlights) > 1e-4  { corrAttrs.append("crs:LocalHighlights2012=\"\(fmt(a.highlights / 100.0, 4))\"") }
            if abs(a.shadows) > 1e-4     { corrAttrs.append("crs:LocalShadows2012=\"\(fmt(a.shadows / 100.0, 4))\"") }
            if abs(a.whites) > 1e-4      { corrAttrs.append("crs:LocalWhites2012=\"\(fmt(a.whites / 100.0, 4))\"") }
            if abs(a.blacks) > 1e-4      { corrAttrs.append("crs:LocalBlacks2012=\"\(fmt(a.blacks / 100.0, 4))\"") }
            if abs(a.temperature) > 1e-4 { corrAttrs.append("crs:LocalTemperature=\"\(fmt(a.temperature / 100.0, 4))\"") }
            if abs(a.tint) > 1e-4        { corrAttrs.append("crs:LocalTint=\"\(fmt(a.tint / 100.0, 4))\"") }
            if abs(a.saturation) > 1e-4  { corrAttrs.append("crs:LocalSaturation=\"\(fmt(a.saturation / 100.0, 4))\"") }
            if abs(a.texture) > 1e-4     { corrAttrs.append("crs:LocalTexture=\"\(fmt(a.texture / 100.0, 4))\"") }
            if abs(a.clarity) > 1e-4     { corrAttrs.append("crs:LocalClarity2012=\"\(fmt(a.clarity / 100.0, 4))\"") }
            if abs(a.dehaze) > 1e-4      { corrAttrs.append("crs:LocalDehaze=\"\(fmt(a.dehaze / 100.0, 4))\"") }
            if abs(a.sharpen) > 1e-4     { corrAttrs.append("crs:LocalSharpness=\"\(fmt(a.sharpen / 100.0, 4))\"") }
            if abs(a.denoise) > 1e-4     { corrAttrs.append("crs:LocalLuminanceNoise=\"\(fmt(a.denoise / 100.0, 4))\"") }
            if abs(a.hueShift) > 1e-4    { corrAttrs.append("crs:LocalHue=\"\(fmt(a.hueShift / 180.0, 4))\"") }

            var subMasksXML: [String] = []
            // 主蒙版作为第 0 个 Mask（blendMode = 0 Add）
            if let primaryXML = serializeSingleMaskComponent(
                kind: m.kind, enabled: true, inverted: m.inverted, op: .add,
                x0: m.x0, y0: m.y0, x1: m.x1, y1: m.y1,
                radius: m.radius, radiusX: m.radiusX, radiusY: m.radiusY,
                radialAngle: m.radialAngle, feather: m.feather,
                strokes: m.strokes, sampleRGB: m.sampleRGB, tolerance: m.tolerance,
                lumLow: m.lumLow, lumHigh: m.lumHigh, lumSoft: m.lumSoft,
                fmt: fmt
            ) {
                subMasksXML.append(primaryXML)
            }
            // 布尔子蒙版（加=0 / 减=1 / 交=2）
            for comp in m.components {
                if let compXML = serializeSingleMaskComponent(
                    kind: comp.kind, enabled: comp.enabled, inverted: comp.inverted, op: comp.op,
                    x0: comp.x0, y0: comp.y0, x1: comp.x1, y1: comp.y1,
                    radius: comp.radius, radiusX: comp.radiusX, radiusY: comp.radiusY,
                    radialAngle: comp.radialAngle, feather: comp.feather,
                    strokes: comp.strokes, sampleRGB: comp.sampleRGB, tolerance: comp.tolerance,
                    lumLow: comp.lumLow, lumHigh: comp.lumHigh, lumSoft: comp.lumSoft,
                    fmt: fmt
                ) {
                    subMasksXML.append(compXML)
                }
            }
            guard !subMasksXML.isEmpty else { continue }

            let attrsJoined = corrAttrs.joined(separator: "\n                 ")
            let subsJoined = subMasksXML.joined(separator: "\n")
            let group = """
                      <rdf:li>
                        <rdf:Description
                         \(attrsJoined)>
                        <crs:CorrectionMasks>
                          <rdf:Seq>
            \(subsJoined)
                          </rdf:Seq>
                        </crs:CorrectionMasks>
                        </rdf:Description>
                      </rdf:li>
            """
            groupEntries.append(group)
        }

        guard !groupEntries.isEmpty else { return "" }
        return """
              <crs:MaskGroupBasedCorrections>
                <rdf:Seq>
        \(groupEntries.joined(separator: "\n"))
                </rdf:Seq>
              </crs:MaskGroupBasedCorrections>
        """
    }

    private static func serializeSingleMaskComponent(
        kind: MaskKind, enabled: Bool, inverted: Bool, op: MaskBoolOp,
        x0: Double, y0: Double, x1: Double, y1: Double,
        radius: Double, radiusX: Double?, radiusY: Double?,
        radialAngle: Double, feather: Double,
        strokes: [Stroke], sampleRGB: [Double], tolerance: Double,
        lumLow: Double, lumHigh: Double, lumSoft: Double,
        fmt: (Double, Int) -> String
    ) -> String? {
        let blendMode: Int = (op == .add ? 0 : op == .subtract ? 1 : 2)
        let activeStr = enabled ? "true" : "false"
        let invStr = inverted ? "true" : "false"
        let baseAttrs = "crs:MaskActive=\"\(activeStr)\" crs:MaskBlendMode=\"\(blendMode)\" crs:MaskInverted=\"\(invStr)\" crs:MaskValue=\"1\""

        switch kind {
        case .linear:
            // Phos: (x0,y0) 为选区全白点(Full)，(x1,y1) 为衰减归零点(Zero)，Y 向上；LR Y 向下
            return """
                            <rdf:li crs:What="Mask/Gradient" \(baseAttrs)
                             crs:FullX="\(fmt(x0, 6))" crs:FullY="\(fmt(1.0 - y0, 6))"
                             crs:ZeroX="\(fmt(x1, 6))" crs:ZeroY="\(fmt(1.0 - y1, 6))"/>
            """
        case .radial:
            let rx = radiusX ?? radius
            let ry = radiusY ?? radius
            let cx = x0, cyLR = 1.0 - y0
            let left = cx - rx, right = cx + rx
            let top = cyLR - ry, bottom = cyLR + ry
            let lrFeather = Int((min(max(feather, 0), 1) * 100).rounded())
            return """
                            <rdf:li crs:What="Mask/CircularGradient" \(baseAttrs)
                             crs:Left="\(fmt(left, 6))" crs:Top="\(fmt(top, 6))"
                             crs:Right="\(fmt(right, 6))" crs:Bottom="\(fmt(bottom, 6))"
                             crs:Angle="\(fmt(-radialAngle, 3))" crs:Feather="\(lrFeather)" crs:Flipped="true"/>
            """
        case .luminanceRange:
            let lo = min(max(lumLow, 0), 1), hi = min(max(lumHigh, lo), 1)
            let sLo = max(0, lo - lumSoft), sHi = min(1, hi + lumSoft)
            let lumStr = "\(fmt(sLo, 4)) \(fmt(lo, 4)) \(fmt(hi, 4)) \(fmt(sHi, 4))"
            return """
                            <rdf:li crs:What="Mask/RangeMask" \(baseAttrs)
                             crs:Type="2" crs:LumRange="\(lumStr)" crs:LuminanceDepthSampleInfo="0 0.5 0.5"/>
            """
        case .colorRange:
            let r = sampleRGB.count >= 3 ? sampleRGB[0] : 0.5
            let g = sampleRGB.count >= 3 ? sampleRGB[1] : 0.5
            let b = sampleRGB.count >= 3 ? sampleRGB[2] : 0.5
            let amt = Int((min(max(tolerance / 0.6, 0), 1) * 100).rounded())
            return """
                            <rdf:li crs:What="Mask/RangeMask" \(baseAttrs)
                             crs:Type="1" crs:ColorAmount="\(amt)"
                             crs:SampleRGB="\(fmt(r, 4)) \(fmt(g, 4)) \(fmt(b, 4))"/>
            """
        case .brush:
            guard !strokes.isEmpty else { return nil }
            let st = strokes[0]
            let dabs = strokes.flatMap { s -> [String] in
                s.points.prefix(250).map { pt in
                    "                <rdf:li>d \(fmt(pt.x, 5)) \(fmt(1.0 - pt.y, 5))</rdf:li>"
                }
            }.prefix(600).joined(separator: "\n")
            return """
                            <rdf:li>
                              <rdf:Description crs:What="Mask/Paint" \(baseAttrs)
                               crs:Radius="\(fmt(st.radius, 5))" crs:Feather="\(fmt(st.feather, 4))" crs:Flow="1">
                                <crs:Dabs>
                                  <rdf:Seq>
            \(dabs)
                                  </rdf:Seq>
                                </crs:Dabs>
                              </rdf:Description>
                            </rdf:li>
            """
        case .subject, .foreground, .sky, .background, .person, .faceSkin, .bodySkin, .eyes, .eyebrows, .lips, .teeth, .hair, .clothes:
            let (subType, subCat): (Int, Int?) = {
                switch kind {
                case .subject, .foreground: return (1, nil)
                case .sky:                  return (2, nil)
                case .background:           return (4, nil)
                case .person:               return (3, 1)
                case .faceSkin:             return (3, 2)
                case .bodySkin:             return (3, 3)
                case .eyebrows:             return (3, 4)
                case .eyes:                 return (3, 5)
                case .lips:                 return (3, 7)
                case .teeth:                return (3, 8)
                case .hair:                 return (3, 9)
                case .clothes:              return (3, 10)
                default:                    return (1, nil)
                }
            }()
            let catAttr = subCat.map { " crs:MaskSubCategoryID=\"\($0)\"" } ?? ""
            return """
                            <rdf:li crs:What="Mask/Image" \(baseAttrs)
                             crs:MaskSubType="\(subType)"\(catAttr)/>
            """
        case .depth:
            return nil
        }
    }

    // MARK: - XMP 解析器（含 MaskGroupBasedCorrections + UprightFourSegments）

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
        private var uprightSegMap: [Int: UprightGuide] = [:]

        // 局部蒙版解析上下文
        private struct PendingMaskComponent {
            var what = ""
            var active = true
            var inverted = false
            var blendMode = 0
            var attrs: [String: String] = [:]
            var dabs: [CGPoint] = []
        }
        private struct PendingMaskGroup {
            var name = ""
            var active = true
            var adjust = LocalAdjust()
            var masks: [PendingMaskComponent] = []
        }
        private var inMaskGroups = false
        private var inCorrectionMasks = false
        private var inDabs = false
        private var currentGroup: PendingMaskGroup? = nil
        private var currentComp: PendingMaskComponent? = nil

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            elementCount += 1
            if elementCount > 25000 || stack.count > 40 { rejected = true; parser.abortParsing(); return }
            stack.append(elementName)
            text = ""

            if elementName == "crs:MaskGroupBasedCorrections" {
                inMaskGroups = true
                return
            }
            if inMaskGroups {
                if elementName == "crs:CorrectionMasks" {
                    inCorrectionMasks = true
                    return
                }
                if elementName == "crs:Dabs" {
                    inDabs = true
                    return
                }
                if inCorrectionMasks {
                    if let what = attributes["crs:What"], what.hasPrefix("Mask/") {
                        var comp = PendingMaskComponent()
                        comp.what = what
                        comp.active = (attributes["crs:MaskActive"]?.lowercased() ?? "true") != "false"
                        comp.inverted = (attributes["crs:MaskInverted"]?.lowercased() ?? "false") == "true"
                        comp.blendMode = Int(attributes["crs:MaskBlendMode"] ?? "0") ?? 0
                        comp.attrs = attributes
                        currentComp = comp
                    }
                    return
                } else {
                    if attributes["crs:What"] == "Correction" || (elementName == "rdf:Description" && currentGroup != nil) {
                        if currentGroup == nil { currentGroup = PendingMaskGroup() }
                        parseCorrectionAttributes(attributes)
                    } else if elementName == "rdf:li", stack.dropLast().last == "rdf:Seq",
                              stack.contains("crs:MaskGroupBasedCorrections"), !inCorrectionMasks {
                        currentGroup = PendingMaskGroup()
                        if !attributes.isEmpty { parseCorrectionAttributes(attributes) }
                    }
                    return
                }
            }

            if elementName == "rdf:Description" || elementName == "Description" {
                applyAttributes(attributes)
            }
            if ["crs:ToneCurvePV2012", "crs:ToneCurvePV2012Red", "crs:ToneCurvePV2012Green", "crs:ToneCurvePV2012Blue"].contains(elementName) {
                curvePoints = []
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
            if text.count > 16384 { rejected = true; parser.abortParsing() }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if inMaskGroups {
                if inDabs && elementName == "rdf:li" && !trimmed.isEmpty {
                    let parts = trimmed.split(separator: " ")
                    if parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]),
                       x.isFinite, y.isFinite {
                        currentComp?.dabs.append(CGPoint(x: min(max(x, 0), 1), y: min(max(1.0 - y, 0), 1)))
                    }
                } else if elementName == "crs:Dabs" {
                    inDabs = false
                } else if inCorrectionMasks && elementName == "rdf:li", let comp = currentComp {
                    currentGroup?.masks.append(comp)
                    currentComp = nil
                } else if elementName == "crs:CorrectionMasks" {
                    inCorrectionMasks = false
                } else if !inCorrectionMasks && elementName == "rdf:li",
                          let grp = currentGroup,
                          stack.dropLast().last == "rdf:Seq" {
                    finalizeMaskGroup(grp)
                    currentGroup = nil
                } else if elementName == "crs:MaskGroupBasedCorrections" {
                    inMaskGroups = false
                }
                if !stack.isEmpty { stack.removeLast() }
                text = ""
                return
            }

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

        private func parseCorrectionAttributes(_ attrs: [String: String]) {
            guard var g = currentGroup else { return }
            func num(_ k: String) -> Double? { attrs[k].flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil } }
            func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
            if let name = attrs["crs:CorrectionName"], !name.isEmpty { g.name = name }
            if let act = attrs["crs:CorrectionActive"] { g.active = act.lowercased() != "false" }
            if let v = num("crs:LocalExposure2012")    { g.adjust.exposure    = clamp(v * 4.0, -4, 4) }
            if let v = num("crs:LocalContrast2012")    { g.adjust.contrast    = clamp(v * 100.0, -100, 100) }
            if let v = num("crs:LocalHighlights2012")  { g.adjust.highlights  = clamp(v * 100.0, -100, 100) }
            if let v = num("crs:LocalShadows2012")     { g.adjust.shadows     = clamp(v * 100.0, -100, 100) }
            if let v = num("crs:LocalWhites2012")      { g.adjust.whites      = clamp(v * 100.0, -100, 100) }
            if let v = num("crs:LocalBlacks2012")      { g.adjust.blacks      = clamp(v * 100.0, -100, 100) }
            if let v = num("crs:LocalTemperature")     { g.adjust.temperature = clamp(v * 100.0, -100, 100) }
            if let v = num("crs:LocalTint")            { g.adjust.tint        = clamp(v * 100.0, -100, 100) }
            if let v = num("crs:LocalSaturation")      { g.adjust.saturation  = clamp(v * 100.0, -100, 100) }
            if let v = num("crs:LocalTexture")         { g.adjust.texture     = clamp(v * 100.0, -100, 100) }
            if let v = num("crs:LocalClarity2012")     { g.adjust.clarity     = clamp(v * 100.0, -100, 100) }
            if let v = num("crs:LocalDehaze")          { g.adjust.dehaze      = clamp(v * 100.0, -100, 100) }
            if let v = num("crs:LocalSharpness")       { g.adjust.sharpen     = clamp(v * 100.0, 0, 100) }
            if let v = num("crs:LocalLuminanceNoise")  { g.adjust.denoise     = clamp(v * 100.0, 0, 100) }
            if let v = num("crs:LocalHue")             { g.adjust.hueShift    = clamp(v * 180.0, -180, 180) }
            currentGroup = g
        }

        private func buildMaskComponent(from c: PendingMaskComponent) -> MaskComponent? {
            func num(_ k: String) -> Double? { c.attrs[k].flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil } }
            let op: MaskBoolOp = c.blendMode == 1 ? .subtract : c.blendMode == 2 ? .intersect : .add
            var comp = MaskComponent(op: op, kind: .linear)
            comp.enabled = c.active
            comp.inverted = c.inverted

            switch c.what {
            case "Mask/Gradient":
                guard let fx = num("crs:FullX"), let fy = num("crs:FullY"),
                      let zx = num("crs:ZeroX"), let zy = num("crs:ZeroY") else { return nil }
                comp.kind = .linear
                comp.x0 = fx; comp.y0 = 1.0 - fy
                comp.x1 = zx; comp.y1 = 1.0 - zy
                comp.gradientVersion = 2
                return comp

            case "Mask/CircularGradient":
                guard let l = num("crs:Left"), let r = num("crs:Right"),
                      let t = num("crs:Top"), let b = num("crs:Bottom") else { return nil }
                comp.kind = .radial
                comp.x0 = (l + r) * 0.5
                comp.y0 = 1.0 - (t + b) * 0.5
                comp.radiusX = max(0.01, abs(r - l) * 0.5)
                comp.radiusY = max(0.01, abs(b - t) * 0.5)
                comp.radialAngle = -(num("crs:Angle") ?? 0)
                let fVal = num("crs:Feather") ?? 50
                comp.feather = min(max(fVal > 1.0 ? fVal / 100.0 : fVal, 0), 1)
                comp.gradientVersion = 1
                // LR Flipped == false 表示选区在圆外，与 Phos 默认圆内相反
                if (c.attrs["crs:Flipped"]?.lowercased() ?? "true") == "false" {
                    comp.inverted = !comp.inverted
                }
                return comp

            case "Mask/RangeMask":
                let typ = Int(c.attrs["crs:Type"] ?? "0") ?? 0
                if typ == 2 {
                    comp.kind = .luminanceRange
                    let vals = (c.attrs["crs:LumRange"] ?? "").split(separator: " ").compactMap { Double($0) }
                    if vals.count >= 4 {
                        comp.lumLow = min(max(vals[1], 0), 1)
                        comp.lumHigh = min(max(vals[2], comp.lumLow), 1)
                        comp.lumSoft = min(max(max(vals[1] - vals[0], vals[3] - vals[2]), 0.01), 0.5)
                    }
                    return comp
                } else {
                    comp.kind = .colorRange
                    let amt = num("crs:ColorAmount") ?? 50
                    comp.tolerance = min(max(amt / 100.0 * 0.6, 0.02), 0.8)
                    let rgb = (c.attrs["crs:SampleRGB"] ?? "").split(separator: " ").compactMap { Double($0) }
                    if rgb.count >= 3 { comp.sampleRGB = Array(rgb.prefix(3)) }
                    return comp
                }

            case "Mask/Paint":
                comp.kind = .brush
                let rad = num("crs:Radius") ?? 0.05
                let fth = num("crs:Feather") ?? 0.5
                if !c.dabs.isEmpty {
                    comp.strokes = [Stroke(pts: c.dabs.map { [Double($0.x), Double($0.y)] },
                                           radius: min(max(rad, 0.005), 0.35),
                                           feather: min(max(fth, 0), 1))]
                }
                return comp

            case "Mask/Image":
                let sub = Int(c.attrs["crs:MaskSubType"] ?? "1") ?? 1
                let cat = Int(c.attrs["crs:MaskSubCategoryID"] ?? "0") ?? 0
                switch sub {
                case 2: comp.kind = .sky
                case 4: comp.kind = .background
                case 3:
                    switch cat {
                    case 2:  comp.kind = .faceSkin
                    case 3:  comp.kind = .bodySkin
                    case 4:  comp.kind = .eyebrows
                    case 5, 6: comp.kind = .eyes
                    case 7:  comp.kind = .lips
                    case 8:  comp.kind = .teeth
                    case 9:  comp.kind = .hair
                    case 10: comp.kind = .clothes
                    default: comp.kind = .person
                    }
                default:
                    comp.kind = .subject
                }
                return comp

            default:
                return nil
            }
        }

        private func finalizeMaskGroup(_ grp: PendingMaskGroup) {
            let comps = grp.masks.compactMap { buildMaskComponent(from: $0) }
            guard let first = comps.first else { return }
            var m = first.asMask()
            m.enabled = grp.active
            m.name = grp.name.isEmpty ? first.kind.label : grp.name
            m.adjust = grp.adjust
            if comps.count > 1 {
                m.components = Array(comps.dropFirst())
            }
            result.params.masks.append(m)
            result.hasEdits = true
        }

        func applyCropResult() {
            if !uprightSegMap.isEmpty {
                let ordered = uprightSegMap.keys.sorted().compactMap { uprightSegMap[$0] }
                if ordered.count >= 2 {
                    result.params.uprightGuides = Array(ordered.prefix(4))
                    result.hasEdits = true
                }
            }
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
            if key.hasPrefix("crs:UprightFourSegments"),
               let idx = Int(key.dropFirst("crs:UprightFourSegments".count)),
               (0...3).contains(idx) {
                let nums = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if nums.count == 4 {
                    uprightSegMap[idx] = UprightGuide(
                        x0: clamp(nums[0], 0, 1), y0: clamp(1.0 - nums[1], 0, 1),
                        x1: clamp(nums[2], 0, 1), y1: clamp(1.0 - nums[3], 0, 1)
                    )
                }
                return
            }
            switch key {
            case "xmp:Rating":
                if let r = Int(value) {
                    if r < 0 {
                        result.rejected = true; result.rating = 0; result.picked = false
                    } else {
                        result.rejected = false; result.rating = min(max(r, 0), 5)
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
            case "crs:CameraProfile":
                if !value.isEmpty {
                    let available = DCPProfileEngine.availableProfiles()
                    if let hit = available.first(where: { $0.id == value || $0.name == value }) {
                        result.params.cameraProfileName = hit.id
                        result.hasEdits = true
                    }
                }
            case "crs:PerspectiveVertical":
                if let v = num() { result.params.perspectiveV = clamp(v, -100, 100); result.hasEdits = true }
            case "crs:PerspectiveHorizontal":
                if let v = num() { result.params.perspectiveH = clamp(v, -100, 100); result.hasEdits = true }
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
