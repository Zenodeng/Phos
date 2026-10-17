import AppKit
import CoreImage

@main struct PhotoAITest {
    @MainActor static func main() async {
        do { try await run() } catch { try? PhotoAIService.shared.lastResponseText.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("last-response.txt"),atomically:true,encoding:.utf8); FileHandle.standardError.write(Data("FAILED: \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var checks = [String]()
        func check(_ ok: Bool,_ name: String) { if !ok { FileHandle.standardError.write(Data("FAILED: \(name)\n".utf8)); exit(1) }; checks.append(name); print("PASS: \(name)"); fflush(stdout) }
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
        let exactCrop = try PhotoAICrop.explicit("仅裁去左右各5%，保留完整高度，不要旋转。")!
        check(abs(exactCrop.x-0.05)<1e-9 && abs(exactCrop.width-0.9)<1e-9 && exactCrop.height == 1,"explicit crop percentages use exact validated arithmetic")
        let ambiguousCrop = try PhotoAICrop.explicit("稍微优化构图")
        check(ambiguousCrop == nil,"ambiguous composition remains model-directed")
        do { _ = try PhotoAICrop.explicit("裁去左右各40%，保留完整高度"); preconditionFailure("aggressive explicit crop accepted") } catch { checks.append("explicit excessive crop remains rejected") }
        let selectedAdapter = try PhotoAIService.shared.adapterDirectory()
        check(selectedAdapter != nil,"production-compatible pilot adapter selected and hash verified")
        let synthetic = CIImage(color:CIColor(red:0.4,green:0.4,blue:0.4)).cropped(to:CGRect(x:0,y:0,width:200,height:200))
        let directional = try PhotoAIPlan.decode(#"{"summary":"区域提亮","adjustments":{},"masks":[{"kind":"linear","target":"region","brightness":"brighten","geometry":{"x0":0.2,"y0":0,"x1":0.8,"y1":1},"adjustments":{"exposure":0.4}}]}"#)
        let bright = try directional.applying(to:EditParams())
        try PhotoAIDirectionCheck.validate(source:synthetic,base:EditParams(),proposed:bright,regions:directional.masks)
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
        let style = try await PhotoAIService.shared.plan(jpeg:input.1,instruction:"用 HSL 将绿色饱和度降至 -15；用亮度曲线轻提中间调；阴影颜色分级用210度蓝色、饱和度8。不要新增蒙版。",base:original)
        try JSONEncoder().encode(style).write(to:out.appendingPathComponent("real-style-plan.json"))
        let styled = try style.applying(to:original)
        check(!styled.hsl.isNeutral && !styled.lumaCurve.isIdentity && !styled.gradeShadow.isNeutral,"real model uses HSL, luma curve and color grading")

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
