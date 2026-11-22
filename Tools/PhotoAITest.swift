import AppKit
import CoreImage
import Darwin

@main struct PhotoAITest {
    @MainActor static func main() async {
        do { try await run() } catch { try? PhotoAIService.shared.lastResponseText.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("last-response.txt"),atomically:true,encoding:.utf8); FileHandle.standardError.write(Data("FAILED: \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var checks = [String]()
        func check(_ ok: Bool,_ name: String) { if !ok { FileHandle.standardError.write(Data("FAILED: \(name)\n".utf8)); exit(1) }; checks.append(name); print("PASS: \(name)"); fflush(stdout) }
        let occupied = socket(AF_INET,SOCK_STREAM,0)
        check(occupied >= 0,"port conflict fixture creates socket")
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(occupied,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        check(bound == 0 && listen(occupied,1) == 0,"port conflict fixture holds a listening port")
        var addressSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(occupied,$0,&addressSize) } }
        check(named == 0,"occupied port can be identified")
        let occupiedPort = UInt16(bigEndian:address.sin_port)
        let fallbackPort = try PhotoAIService.availableLocalPort(preferred:occupiedPort)
        check(fallbackPort > 0 && fallbackPort != occupiedPort,"occupied local port selects a different kernel-assigned port")
        close(occupied)
        let reusedPort = try PhotoAIService.availableLocalPort(preferred:occupiedPort)
        check(reusedPort == occupiedPort,"available preferred port remains compatible")
        check(PhotoAIService.serializationVersion == "phos-json-compact-v1" && PhotoAIService.decoderFingerprint.count == 64,"versioned constrained decoding protocol is declared")
        let onlyVibrance = "只把鲜艳度设置为10，现有曝光、对比度、颗粒、白平衡、曲线及其他编辑全部保持不变，不要新增蒙版。"
        check(PhotoAIService.exclusiveSlider(onlyVibrance) == "vibrance","exclusive numeric request locks all other editing tools")
        check(PhotoAIService.exclusiveSlider("只把鲜艳度设置为10，同时把曝光设置为0.2 EV") == nil,"compound requests do not become single-slider locks")
        let cropSize = CGSize(width:1920,height:1080)
        let protection = CGRect(x:0.37,y:0.14,width:0.23,height:0.72)
        let aspect = PhotoAICropComposition.requestedAspect("做成竖版四比五，保留整个人物")
        check(aspect == 0.8 && PhotoAICropComposition.requestedAspect("不要裁成 4:5") == nil,"aspect reads explicit positive instructions")
        let aspectBox = try PhotoAICropComposition.compose(PhotoAICropComposition.full,size:cropSize,aspect:aspect,protected:protection)
        check(abs(cropSize.width*aspectBox.width/(cropSize.height*aspectBox.height)-0.8) < 0.00001 &&
              CGRect(x:aspectBox.x,y:aspectBox.y,width:aspectBox.width,height:aspectBox.height).contains(protection),
              "fixed aspect is calculated in pixels and keeps the detected subject")
        let narrow = try PhotoAICropComposition.compose(PhotoAICropComposition.full,size:cropSize,aspect:9.0/16,protected:protection)
        check(narrow.width < 0.35 && narrow.confirmedAspect != nil,"explicit portrait aspect uses a verified tighter crop")
        let narrowState = try narrow.applying(to:EditParams(),imageSize:cropSize)
        check(narrowState.cropW == narrow.width,"validated explicit aspect applies through the native crop path")
        let wire = try JSONEncoder().encode(narrow)
        let untrusted = try JSONDecoder().decode(PhotoAICrop.self,from:wire)
        check(untrusted.confirmedAspect == nil,"decoded proposals cannot grant themselves the tighter aspect allowance")
        let shifted = try PhotoAICropComposition.compose(PhotoAICrop(x:0.06,y:0.06,width:0.98,height:0.98),size:cropSize,protected:protection)
        check(abs(shifted.x-0.02)<0.00001 && abs(shifted.y-0.02)<0.00001 && shifted.width == 0.98,"slight out-of-bounds proposal preserves size and is translated into the preview")
        do { _ = try PhotoAICropComposition.compose(PhotoAICrop(x:0.4,y:0.2,width:0.9,height:0.7),size:cropSize,protected:protection); preconditionFailure("gross overflow accepted") } catch { checks.append("gross crop overflow rejected") }
        do { _ = try PhotoAICropComposition.compose(PhotoAICropComposition.full,size:cropSize,aspect:0.8,protected:CGRect(x:0.02,y:0.2,width:0.96,height:0.6)); preconditionFailure("subject clipped by aspect") } catch { checks.append("fixed aspect rejects incompatible subject envelope") }
        let focusedLocal = "把人物身后的背景稍微压暗一些，人物原有光线保持不变。只做局部调整，保留原有全局设置。"
        let intent = PhotoAILocalIntent.explicit(focusedLocal)
        check(!PhotoAIService.shouldAttemptCrop(focusedLocal) && !PhotoAIService.shouldAttemptCrop(onlyVibrance),
              "automatic composition preserves framing for local-only and exclusive-slider requests")
        check(PhotoAIService.shouldAttemptCrop("先裁成四比五竖版。"+focusedLocal),
              "explicit crop still runs before the requested local adjustment")
        check(intent?.target == "background" && intent?.brightness == "darken" && intent?.kinds == ["person"],"explicit local request isolates semantic selection and direction")
        check(!PhotoAILocalIntent.onlyLocal("整体曝光设置为0.2 EV；只对亮区压暗一点。"),"compound global and local requests preserve the planner vocabulary")
        let localSchema = PhotoAIService.editingSchema(focusedLocal)["properties"] as! [String:Any]
        let localMasks = localSchema["masks"] as! [String:Any]
        let maskFields = (localMasks["items"] as! [String:Any])["properties"] as! [String:Any]
        check(localMasks["minItems"] as? Int == 1 && localMasks["maxItems"] as? Int == 1 &&
              (maskFields["target"] as? [String:Any])?["enum"] as? [String] == ["background"] &&
              (maskFields["brightness"] as? [String:Any])?["enum"] as? [String] == ["darken"],
              "local grammar pins one mask to the requested region and direction")
        check((localSchema["adjustments"] as? [String:Any])?["properties"] as? [String:Any] != nil &&
              ((localSchema["adjustments"] as! [String:Any])["properties"] as! [String:Any]).isEmpty &&
              localSchema["curves"] == nil && localSchema["hsl"] == nil && localSchema["grading"] == nil,
              "explicit local grammar locks sliders, curves, HSL and grading")
        let wrongLocal = try PhotoAIPlan.decode(#"{"summary":"调整","adjustments":{},"masks":[{"kind":"person","target":"subject","brightness":"darken","adjustments":{"exposure":-0.25}}]}"#)
        do { try PhotoAIService.validateRequested(wrongLocal,base:EditParams(),instruction:focusedLocal);preconditionFailure("wrong target accepted") } catch { checks.append("direct validation rejects a subject mask when only the background was requested") }
        let scopeLeak = try PhotoAIPlan.decode(#"{"summary":"调整","adjustments":{},"masks":[],"hsl":{"blue":{"sat":12}}}"#)
        do { try PhotoAIService.validateRequested(scopeLeak,base:EditParams(),instruction:focusedLocal);preconditionFailure("global HSL leak accepted") } catch { checks.append("direct validation rejects global HSL in local-only request") }
        let openProperties = PhotoAIService.editingSchema("清透一些，保留傍晚氛围，人物自然亮一点") ["properties"] as! [String:Any]
        check(openProperties["curves"] != nil && openProperties["hsl"] != nil && openProperties["grading"] != nil,"directional requests retain creative tools")
        let partial = PhotoAIService.editingSchema("亮度曲线保持不变，用RGB曲线增强对比") ["properties"] as! [String:Any]
        let channels = (partial["curves"] as! [String:Any])["properties"] as! [String:Any]
        check(channels["luma"] == nil && channels["rgb"] != nil,"preserving a named curve leaves other channels editable")
        let lockedProperties = PhotoAIService.editingSchema(onlyVibrance)["properties"] as! [String:Any]
        check(lockedProperties["curves"] == nil && lockedProperties["hsl"] == nil && lockedProperties["grading"] == nil,"exclusive schema removes advanced fields before decoding")
        let grey = try PhotoAIPlan.decode(#"{"summary":"调整","adjustments":{"vibrance":10},"masks":[],"curves":{"rgb":[[0,0.5],[0.25,0.5],[0.5,0.5],[0.75,0.5],[1,0.5]]}}"#)
        do { try PhotoAIService.validateRequested(grey,base:EditParams(),instruction:onlyVibrance);preconditionFailure("flat grey accepted") } catch {checks.append("flat-grey replay rejected before rendering")}
        do { try PhotoAIService.validateRequested(grey,base:EditParams(),instruction:"鲜艳度调高一点，现有曲线全部保持不变");preconditionFailure("preserved curve overwritten") } catch {checks.append("advanced curve preservation is validated after decoding")}
        try PhotoAIService.validateCapabilityRequest("不要生成式填充，只调整光线和色彩")
        for unsupported in ["请使用生成式填充移除画面中的路人并补齐背景。","请替换成全新的星空，并添加原图不存在的建筑。"] {
            do {_ = try await PhotoAIService.shared.plan(jpeg:Data(),instruction:unsupported,base:EditParams());preconditionFailure("unsupported request reached model")}
            catch {check(error.localizedDescription.contains("仅支持参数修图") && PhotoAIService.shared.lastEditingAttempts.isEmpty,"unsupported pixel generation rejected without model request")}
        }
        let budget = PhotoAIRequestBudget()
        try budget.take(); try budget.take()
        do { try budget.take(); preconditionFailure("retry budget exceeded") } catch { checks.append("schema and render corrections share at most two model requests") }
        try PhotoAIService.validateExplicitNumericRequest("曝光设置为0.2 EV")
        try PhotoAIService.validateExplicitNumericRequest("不要把曝光设置为20 EV，只保留原样")
        do {
            _ = try await PhotoAIService.shared.plan(jpeg:Data(),instruction:"将整体曝光严格设置为20 EV，不接受其他数值。",base:EditParams())
            preconditionFailure("impossible target reached model request")
        } catch { check(error.localizedDescription.contains("超出支持范围"),"explicit impossible exposure is rejected before image/model request") }
        var base = EditParams(); base.grain = 12; base.cropX = 0.1; base.cropW = 0.9; base.masks = [Mask()]
        let text = #"{"summary":"局部提亮","adjustments":{"exposure":0.4},"masks":[{"kind":"person","name":"人物","inverted":true,"adjustments":{"shadows":20}},{"kind":"radial","name":"光线","geometry":{"x0":0.4,"y0":0.6,"radiusX":0.2,"radiusY":0.1},"adjustments":{"exposure":0.2}}]}"#
        let parsed = try PhotoAIPlan.decode("```json\n"+text+"\n```")
        let p = try parsed.applying(to:base)
        check(p.exposure == 0.4 && p.grain == 12 && p.cropX == base.cropX,"absolute parameters and unrelated fields preserved")
        check(p.masks.count == 3 && p.masks[0] == base.masks[0] && p.masks[1].inverted,"existing masks preserved and inverted semantic mask appended")
        check(p.masks[2].gradientVersion == 1 && p.masks[2].radiusX == 0.2,"radial geometry uses native ellipse engine")
        for bad in [#"{"summary":"x","adjustments":{"exposure":100},"masks":[]}"#, #"{"summary":"x","adjustments":{"cropX":0.5},"masks":[]}"#, #"{"summary":"x","adjustments":{},"masks":[{"kind":"sky","name":"sky","adjustments":{"exposure":1}}]}"#, #"{"summary":"x","adjustments":{},"masks":[{"kind":"linear","name":"x","geometry":{"x0":2},"adjustments":{"exposure":1}}]}"#, #"{"summary":"x","adjustments":{},"masks":[{"kind":"luminanceRange","name":"x","geometry":{"lumLow":0.9,"lumHigh":0.1},"adjustments":{"exposure":1}}]}"#] {
            do { _ = try PhotoAIPlan.decode(bad).applying(to:base); preconditionFailure("invalid plan accepted") } catch { checks.append("invalid plan rejected") }
        }
        let advancedText = #"{"summary":"调色","adjustments":{"grain":12,"vignette":-15,"sharpen":0.6},"curves":{"luma":[[0,0],[0.5,0.56],[1,1]]},"hsl":{"green":{"sat":-20,"hue":5}},"grading":{"shadows":{"hue":210,"sat":8}},"masks":[]}"#
        let advanced = try PhotoAIPlan.decode(advancedText).applying(to:base)
        check(advanced.hsl.green.sat == -20 && advanced.gradeShadow.hue == 210 && advanced.gradeShadow.sat == 8 && advanced.lumaCurve.points[1][1] == 0.56 && advanced.sharpen == 0.6,"HSL, curves, color grading and detail controls execute")
        let reversed = #"{"summary":"人物提亮背景压暗","adjustments":{},"masks":[{"kind":"subject","target":"subject","brightness":"brighten","inverted":true,"adjustments":{"exposure":-0.4}},{"kind":"subject","target":"background","brightness":"darken","inverted":false,"adjustments":{"exposure":0.3}}]}"#
        let corrected = try PhotoAIPlan.decode(reversed).applying(to:EditParams())
        check(!corrected.masks[0].inverted && corrected.masks[0].adjust.exposure == 0.4 && corrected.masks[1].inverted && corrected.masks[1].adjust.exposure == -0.3,"selection inversion and exposure signs canonicalized separately")
        let contradictory = try PhotoAIPlan.decode(#"{"summary":"局部","adjustments":{},"masks":[{"kind":"person","target":"subject","brightness":"darken","inverted":true,"adjustments":{"exposure":-0.25}}]}"#)
        let background = try contradictory.enforcing("只创建人物蒙版压暗背景，局部曝光设置为-0.25 EV；全局参数保持不变。")
        check(background.masks[0].target == "background" && background.masks[0].inverted == true && background.masks[0].adjustments["exposure"] == -0.25,"explicit background target overrides contradictory subject label before inversion")
        let subject = try contradictory.enforcing("不要压暗背景，只创建人物蒙版提亮人物。")
        check(subject.masks[0].target == "subject" && subject.masks[0].inverted == false && subject.masks[0].adjustments["exposure"] == 0.25,"negated background clause does not override explicit subject brightening")
        check(PhotoAIPlan.explicitMaskTarget("提亮人物，同时压暗背景") == nil && PhotoAIPlan.explicitMaskTarget("提亮人物并压暗背景") == nil && PhotoAIPlan.explicitMaskTarget("提亮人物旁边的背景") == nil && PhotoAIPlan.explicitMaskTarget("提亮人物身后") == nil && PhotoAIPlan.explicitMaskTarget("自然通透，局部优化") == nil,"mixed and ambiguous mask requests are not forced to a single target")
        var existingCurve = EditParams(); existingCurve.lumaCurve = ToneCurve(points:[[0,0.1],[0.5,0.6],[1,1]])
        check(PhotoAIService.curveRepairHint(instruction:"用亮度曲线轻提中间调",base:EditParams()) != nil && PhotoAIService.curveRepairHint(instruction:"用亮度曲线轻提中间调",base:existingCurve) == nil && PhotoAIService.curveRepairHint(instruction:"不要用亮度曲线轻提中间调",base:EditParams()) == nil,"curve repair example is limited to an explicit gentle lift from identity")
        let flattened = try PhotoAIPlan.decode(#"{"summary":"提亮","adjustments":{},"masks":[],"curves":{"luma":[[0,0.48],[0.25,0.52],[0.5,0.58],[0.75,0.62],[1,0.65]]}}"#)
        do { try PhotoAIService.validateRequested(flattened,base:EditParams(),instruction:"用亮度曲线轻提中间调"); preconditionFailure("flattened tonal range accepted") } catch { checks.append("gentle midtone request rejects a flattened tonal range") }
        let highlights = #"{"summary":"压亮区","adjustments":{},"masks":[{"kind":"luminanceRange","target":"highlights","brightness":"darken","inverted":true,"geometry":{"lumLow":0,"lumHigh":0.3},"adjustments":{"exposure":0.3}}]}"#
        let hp = try PhotoAIPlan.decode(highlights).applying(to:EditParams())
        check(hp.masks[0].lumLow == 0.65 && hp.masks[0].lumHigh == 1 && !hp.masks[0].inverted && hp.masks[0].adjust.exposure == -0.3,"highlight mask cannot select dark pixels or brighten instead")
        let crop = PhotoAICrop(x:0.1,y:0.2,width:0.8,height:0.6)
        let cropped = try crop.applying(to:base,imageSize:CGSize(width:1200,height:800))
        check(abs(cropped.cropX-0.19)<1e-9 && abs(cropped.cropY-0.2)<1e-9 && abs(cropped.cropW-0.72)<1e-9 && abs(cropped.cropH-0.6)<1e-9,"top-left crop maps into existing bottom-left crop")
        check(abs(cropped.masks[0].x0-(base.masks[0].x0-0.1)/0.8)<1e-9,"existing mask geometry reprojected on crop")
        for invalid in [PhotoAICrop(x:0.8,y:0,width:0.5,height:1),PhotoAICrop(x:0,y:0,width:0.1,height:0.1)] {
            do { _ = try invalid.applying(to:base); preconditionFailure("bad crop") } catch { checks.append("invalid crop rejected") }
        }
        let localOnly = "只创建亮度范围蒙版提亮亮区，局部曝光0.35 EV；全局曝光、白平衡和其他参数保持不变。"
        let protected = PhotoAIService.preservedGlobalKeys(localOnly)
        check(protected == Set(PhotoAIPlan.keys.keys),"explicit local-only instruction protects every global slider")
        let constrained = PhotoAIService.editingSchema(localOnly)
        let fields = ((constrained["properties"] as! [String:Any])["adjustments"] as! [String:Any])["properties"] as! [String:Any]
        check(fields.isEmpty,"local-only constrained decoding cannot emit global sliders")
        let unwantedGlobal = try PhotoAIPlan.decode(#"{"summary":"局部","adjustments":{"exposure":0.35},"masks":[]}"#)
        do { try PhotoAIService.validateRequested(unwantedGlobal,base:base,instruction:localOnly); preconditionFailure("global override accepted") } catch { checks.append("post-decode local-only global guard rejects overrides") }
        check(PhotoAIService.preservedGlobalKeys("整体曝光设置为0.2 EV；创建亮度范围蒙版压暗亮区。").isEmpty,"mixed global and local requests remain allowed")
        check(!PhotoAIService.preservedGlobalKeys("仅修改亮度曲线；全局曝光保持不变。").contains("contrast"),"named preservation does not lock unrelated sliders")
        check(!PhotoAIService.preservedGlobalKeys("只把整体曝光设置为0.2 EV，其他参数保持不变，不要新增蒙版。").contains("exposure"),"comma-separated preservation does not contradict explicit exposure request")
        check(PhotoAIService.preservedGlobalKeys("只把颗粒设置为12、暗角设置为-8；不要修改白平衡，不要新增蒙版。") == Set(["temperature","tint"]),"negative mask mention does not protect every slider")
        check(PhotoAIService.preservedGlobalKeys("保持白平衡和曲线不变，只把鲜艳度设置为10，不要新增蒙版。") == Set(["temperature","tint"]),"preserve named white balance while permitting other changes")
        let exactCrop = try PhotoAICrop.explicit("仅裁去左右各5%，保留完整高度，不要旋转。")!
        check(abs(exactCrop.x-0.05)<1e-9 && abs(exactCrop.width-0.9)<1e-9 && exactCrop.height == 1,"explicit crop percentages use exact validated arithmetic")
        let ambiguousCrop = try PhotoAICrop.explicit("稍微优化构图")
        check(ambiguousCrop == nil,"ambiguous composition remains model-directed")
        do { _ = try PhotoAICrop.explicit("裁去左右各40%，保留完整高度"); preconditionFailure("aggressive explicit crop accepted") } catch { checks.append("explicit excessive crop remains rejected") }
        let compactDefault = try PhotoAIService.editingPrompt(instruction:"曝光设置为0.2 EV",base:EditParams())
        check(compactDefault.contains("defaults except {}"),"production prompt compacts only defaults")
        var withExisting = EditParams(); withExisting.exposure = 0.4; withExisting.grain = 7
        let compactExisting = try PhotoAIService.editingPrompt(instruction:"只修改对比度",base:withExisting)
        check(compactExisting.contains("\"exposure\":0.4") && compactExisting.contains("\"grain\":7"),"shared training prompt preserves existing nondefault edits")
        check(PhotoAIService.cropPrompt(instruction:"不要裁切").contains("origin TOP LEFT"),"shared crop prompt retains coordinate convention")
        let selectedAdapter = try PhotoAIService.shared.adapterDirectory()
        check(selectedAdapter != nil,"production-compatible pilot adapter selected and hash verified")
        let synthetic = CIImage(color:CIColor(red:0.4,green:0.4,blue:0.4)).cropped(to:CGRect(x:0,y:0,width:200,height:200))
        let directional = try PhotoAIPlan.decode(#"{"summary":"区域提亮","adjustments":{},"masks":[{"kind":"linear","target":"region","brightness":"brighten","geometry":{"x0":0.2,"y0":0,"x1":0.8,"y1":1},"adjustments":{"exposure":0.4}}]}"#)
        let bright = try directional.applying(to:EditParams())
        try PhotoAIDirectionCheck.validate(source:synthetic,base:EditParams(),proposed:bright,regions:directional.masks)
        try PhotoAIDirectionCheck.validate(source:synthetic,base:EditParams(),proposed:bright,regions:directional.masks,protectOutside:true)
        checks.append("native spatial render protects the unselected area for a gentle gradient")
        let syntheticPreview = try PhotoAIEditor.preview(source:synthetic,params:EditParams())
        let exactPortrait = try await PhotoAIService.shared.crop(jpeg:syntheticPreview.1,instruction:"裁成四比五竖版")
        let fixedParams = try exactPortrait.applying(to:EditParams(),imageSize:CGSize(width:200,height:200))
        let fixedPreview = try PhotoAIEditor.preview(source:synthetic,params:fixedParams)
        check(fixedPreview.0.width == 160 && fixedPreview.0.height == 200,"production crop entry renders the exact requested pixel aspect, got \(fixedPreview.0.width)×\(fixedPreview.0.height)")
        var wrong = bright; wrong.masks[0].adjust.exposure = -0.4
        do { try PhotoAIDirectionCheck.validate(source:synthetic,base:EditParams(),proposed:wrong,regions:directional.masks); preconditionFailure("wrong direction") } catch { checks.append("actual darkening rejected for brighten intent") }
        check(Engine.render(synthetic,try PhotoAICrop(x:0.1,y:0.2,width:0.8,height:0.6).applying(to:EditParams())).extent.width == 160,"crop changes rendered pixels, not only metadata")
        let imageURL = out.appendingPathComponent("fixture.jpg")
        try FileManager.default.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[2]),to:imageURL)
        let state = AppState(); state.openFolder(out)
        for _ in 0..<1000 { if state.source != nil && state.preview != nil && !state.previewing { break }; try await Task.sleep(nanoseconds:10_000_000) }
        guard let source = state.source else { fatalError("fixture decode") }
        let original = state.params, undoIndex = state.history.index
        let input = try PhotoAIEditor.preview(source:source,params:original)
        let autoBox = try await PhotoAIService.shared.crop(jpeg:input.1,instruction:"适度裁去左边缘，保持日落与树完整，改善构图。")
        _ = try autoBox.applying(to:original,imageSize:CGSize(width:input.0.width,height:input.0.height))
        try JSONEncoder().encode(autoBox).write(to:out.appendingPathComponent("real-crop.json"))
        checks.append("real model proposes valid crop")
        let plan: PhotoAIPlan
        do { plan = try await PhotoAIService.shared.plan(jpeg:input.1,instruction:"保留日落暖色，整体曝光设置为 0.2 EV；创建亮度范围蒙版，仅对亮区降低 0.3 EV 曝光。",base:original) } catch { try PhotoAIService.shared.lastResponseText.write(to:out.appendingPathComponent("invalid-response.txt"),atomically:true,encoding:.utf8); throw error }
        try JSONEncoder().encode(plan).write(to:out.appendingPathComponent("real-model-plan.json"))
        let candidate = try plan.applying(to:original)
        check(state.params == original && state.history.index == undoIndex,"proposal does not modify state or history")
        check(candidate != original && candidate.masks.count == 1 && candidate.masks[0].kind == .luminanceRange && candidate.masks[0].adjust.exposure == -0.3 && candidate.masks[0].lumHigh > candidate.masks[0].lumLow,"real model honors requested luminance mask type, exposure and valid bounds")
        let rendered = try PhotoAIEditor.preview(source:source,params:candidate)
        try rendered.1.write(to:out.appendingPathComponent("candidate.jpg"))
        check(rendered.0.width > 0,"candidate renders through real Phos pipeline")
        try PhotoAIDirectionCheck.validate(source:source,base:original,proposed:candidate,regions:plan.masks)
        checks.append("real model local direction verified from rendered pixels")
        let scopedLight = "只压住画面最亮的区域，暗部的轮廓和层次保持原样。只做局部调整，保留原有全局设置。"
        let localPlan = try await PhotoAIService.shared.plan(jpeg:input.1,instruction:scopedLight,base:original)
        let localCandidate = try localPlan.applying(to:original)
        try PhotoAIDirectionCheck.validate(source:source,base:original,proposed:localCandidate,regions:localPlan.masks,protectOutside:true)
        var withoutNewMasks = localCandidate; withoutNewMasks.masks = original.masks
        check(withoutNewMasks == original && localPlan.masks.count == 1 &&
              localPlan.masks[0].target == "highlights" && localPlan.masks[0].brightness == "darken",
              "real P2 constrains highlights-only edit and protects existing global state")
        try JSONEncoder().encode(localPlan).write(to:out.appendingPathComponent("real-local-only-plan.json"))
        let style = try await PhotoAIService.shared.plan(jpeg:input.1,instruction:"用 HSL 将绿色饱和度降至 -15；用亮度曲线轻提中间调；阴影颜色分级用210度蓝色、饱和度8。不要新增蒙版。",base:original)
        try JSONEncoder().encode(style).write(to:out.appendingPathComponent("real-style-plan.json"))
        try JSONEncoder().encode(PhotoAIService.shared.lastEditingAttempts).write(to:out.appendingPathComponent("real-style-attempts.json"))
        let styled = try style.applying(to:original)
        check(!styled.hsl.isNeutral && !styled.lumaCurve.isIdentity && !styled.gradeShadow.isNeutral,"real model uses HSL, luma curve and color grading")

        var existing = EditParams(); existing.exposure = 0.4; existing.contrast = 3; existing.grain = 7
        let scoped = try await PhotoAIService.shared.plan(jpeg:input.1,instruction:onlyVibrance,base:existing)
        let scopedResult = try scoped.applying(to:existing)
        var expected = existing; expected.vibrance = 10
        check(scopedResult == expected,"real model single-slider proposal preserves entire existing edit stack")
        try JSONEncoder().encode(PhotoAIService.shared.lastEditingAttempts).write(to:out.appendingPathComponent("scoped-attempts.json"))
        state.commit(candidate)
        check(state.params == candidate && state.history.index == undoIndex+1,"apply creates one undo step")
        state.undo(); check(state.params == original,"undo restores all original parameters and masks")
        state.redo(); check(state.params == candidate,"redo restores AI adjustments")
        let sidecar = try SidecarStore.read(for:imageURL)
        check(sidecar?.params == candidate,"AI edits persist in normal sidecar")
        let editor = PhotoAIEditor(); editor.generate(state:state,instruction:"微微提亮")
        editor.cancel(); try await Task.sleep(nanoseconds:500_000_000)
        check(editor.candidate == nil && !editor.busy && state.params == candidate,"cancelled analysis cannot apply edits")
        let router = WorkspaceSheetRouter(state:state); router.request(.photoAI)
        check(router.presented == .photoAI,"AI sheet uses workspace router")
        router.beginDismissal(); router.didDismiss(); check(!state.showPhotoAI,"AI sheet dismiss resets state")
        try JSONSerialization.data(withJSONObject:["status":"passed","checks":checks],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("tests.json"))
        print("PASSED \(checks.count) checks")
        NSApplication.shared.terminate(nil)
    }
}
