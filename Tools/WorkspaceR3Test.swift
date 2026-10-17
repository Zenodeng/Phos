import AppKit
import CoreImage
import SwiftUI

@main struct WorkspaceR3Test {
    @MainActor static func main() async throws {
        try await WorkspaceR2Test.main()
        let url = URL(fileURLWithPath:CommandLine.arguments[1])
        let r2 = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
        let output = url.deletingLastPathComponent()
        var checks = 0
        func check(_ value:@autoclosure () -> Bool,_ name:String) {
            guard value() else { FileHandle.standardError.write(Data("FAIL R3: \(name)\n".utf8)); exit(1) }
            checks += 1; print("PASS R3: \(name)"); fflush(stdout)
        }
        let all = ParameterDescriptor.all, defaults = EditParams()
        check(all.count == 45 && Set(all.map(\.id)).count == all.count,"45 unique global parameter descriptors")
        check(all.allSatisfy { $0.defaultValue == defaults[keyPath:$0.keyPath] && $0.range.contains($0.defaultValue) && !$0.isModified(defaults) },"every default comes from the real model and fits its range")
        check(ParameterDescriptor.named("contrast").response == 1.8 && ParameterDescriptor.named("exposure").unit == "EV","contrast response and exposure units preserved")
        check(ParameterDescriptor.named("sharpen").defaultValue == 0.35 && ParameterDescriptor.named("sharpenRadius").defaultValue == 1 && ParameterDescriptor.named("grainSize").defaultValue == 0.6,"nonzero detail defaults are neutral")
        var edited = defaults
        for field in all { edited[keyPath:field.keyPath] = field.defaultValue == field.range.upperBound ? field.range.lowerBound : field.range.upperBound }
        edited.whiteBalanceGains = [1.2,1,0.9]; edited.hdrMode = true
        edited.curve = ToneCurve(points:[[0,0],[0.5,0.7],[1,1]])
        edited.gradeMid = ColorGrade(hue:30,sat:20); edited.hsl[0].hue = 15
        edited.mono = true; edited.primRed.hue = 10; edited.clutName = "test.cube"
        edited.rotation = 90; edited.flipped = true; edited.perspectiveAuto = true; edited.masks = [Mask()]
        for title in ParameterGroupSchema.titles {
            let reset = ParameterGroupSchema.reset(title,in:edited)
            check(ParameterGroupSchema.modified(title,in:edited) && !ParameterGroupSchema.modified(title,in:reset),"group reset restores actual defaults: "+title)
        }
        check(ParameterGroupSchema.reset("基本",in:edited).masks == edited.masks && ParameterGroupSchema.reset("白平衡",in:edited).curve == edited.curve,"group reset preserves unrelated complex fields")
        for text in ["NaN","Inf","-Inf","1e999","--1","","1,2.3"] { check(ParameterInputPolicy.value(text,in:-100...100) == nil,"invalid numeric input rejected: "+text) }
        check(ParameterInputPolicy.value(" -1,25 ",in:-5...5) == -1.25 && ParameterInputPolicy.value("999",in:-5...5) == 5,"decimal comma, negative values and finite bounds")

        let s = AppState(); s.openFolder(output.appendingPathComponent("photo-fixtures"))
        for _ in 0..<1000 { if s.preview != nil && !s.previewing { break }; try await Task.sleep(nanoseconds:10_000_000) }
        check(s.source != nil,"transaction tests use an actual decoded photo")
        s.commit(defaults); let start = s.params, count = s.history.stack.count, writes = s.workMetrics.snapshot["sidecarWrite"]!
        let token = s.parameterEdits.begin()
        for x in [0.123456789123,0.5,0.75] { s.set(\.exposure,x) }
        check(s.history.stack.count == count && s.workMetrics.snapshot["sidecarWrite"] == writes,"continuous updates only preview before end")
        check(s.parameterEdits.complete(token),"continuous transaction completes once")
        s.endEdit()
        check(s.history.stack.count == count+1 && s.workMetrics.snapshot["sidecarWrite"] == writes+1,"one drag is one history entry and one sidecar write")
        check(!s.parameterEdits.complete(token),"late duplicate end or blur cannot commit twice")
        s.undo(); check(s.params == start,"undo restores entire pre-drag parameters")
        let beforeCancel = s.workMetrics.snapshot["sidecarWrite"]!, history = s.history.stack
        let cancelled = s.parameterEdits.begin(); s.set(\.exposure,1.5); s.parameterEdits.invalidate()
        check(s.params == start && s.history.stack == history && s.workMetrics.snapshot["sidecarWrite"] == beforeCancel,"cancel restores transient parameters without undo or sidecar entries")
        check(!s.parameterEdits.valid(cancelled),"cancel invalidates the original token")
        let pending = s.parameterEdits.begin(); s.set(\.contrast,42)
        var preset = defaults; preset.exposure = -0.7; s.commit(preset)
        check(s.params == preset && !s.parameterEdits.valid(pending),"preset invalidates unfinished work before replacing parameters")
        let undoToken = s.parameterEdits.begin(); s.set(\.exposure,2); s.undo()
        check(!s.parameterEdits.valid(undoToken) && s.params == start,"undo cancels transient work before changing history")
        var numeric:ParameterEditCoordinator.Token?
        var completedOnOldPhoto = false
        let oldID = s.current!.id
        numeric = s.parameterEdits.begin(finish:{
            completedOnOldPhoto = s.current?.id == oldID
            if s.parameterEdits.complete(numeric) { s.set(\.exposure,0.25); s.endEdit() }
        })
        check(s.select(1) && completedOnOldPhoto && !s.parameterEdits.valid(numeric),"selection synchronously finishes the draft on the old photo")
        let unchanged = s.params, unchangedHistory = s.history.stack.count
        let focusOnly = s.parameterEdits.begin(); _ = s.parameterEdits.complete(focusOnly)
        check(s.params == unchanged && s.history.stack.count == unchangedHistory,"focusing without editing never rounds or writes values")
        s.inspectorUI.curveChannel = 3; s.inspectorUI.gradeBand = 2; s.inspectorUI.expanded["曲线"] = false
        s.inspectorUI.category = .detail; s.inspectorUI.category = .color
        check(s.inspectorUI.curveChannel == 3 && s.inspectorUI.gradeBand == 2 && !s.inspectorUI.isExpanded("曲线"),"graph and group state survives category changes")

        let presetURL = output.appendingPathComponent("damaged-presets.json"), bad = Data("{invalid".utf8)
        try bad.write(to:presetURL)
        let catalog = WorkspacePresetCatalog.load(presetURL,fallback:s.defaultPresets)
        check(catalog.error != nil && catalog.presets == s.defaultPresets && (try? Data(contentsOf:presetURL)) == bad,"damaged preset catalog has an error and is never overwritten")
        let presets = s.defaultPresets+[Preset(name:"旅行暖色",params:defaults)]
        check(WorkspacePresetPolicy.filtered(presets,query:"暖色",collection:.personal).count == 1 && WorkspacePresetPolicy.filtered(presets,query:"no-match",collection:.all).isEmpty,"preset collection, search and empty result use actual data")
        var export = ExportSettings()
        check(WorkspaceExportValidation.error(export,edge:"0") == nil,"normal export settings are valid")
        for edge in ["-1","NaN","300.5","100001",""] { check(WorkspaceExportValidation.error(export,edge:edge) != nil,"invalid export size blocks action: "+edge) }
        export.quality = .nan; check(WorkspaceExportValidation.error(export,edge:"0") != nil,"nonfinite output quality rejected")
        export = ExportSettings(); export.format = "exe"; check(WorkspaceExportValidation.error(export,edge:"0") != nil,"unsupported output format rejected")
        export = ExportSettings(); check(WorkspaceExportValidation.error(export,edge:"0",cutout:true) != nil,"alpha output requires PNG or TIFF")
        export.format = "tiff"; export.tiffBitDepth = 16
        check(WorkspaceExportValidation.error(export,edge:"4000",cutout:true) == nil,"16-bit TIFF alpha output remains available")
        export.watermarkEnabled = true; export.watermarkText = " "
        check(WorkspaceExportValidation.error(export,edge:"0") != nil,"blank watermark text blocks output")
        export.watermarkKind = "image"; export.watermarkImagePath = "/no/such/file.png"
        check(WorkspaceExportValidation.error(export,edge:"0") != nil,"unreadable watermark image blocks output")
        check(WorkspacePhotoMetadata.read(output.appendingPathComponent("photo-fixtures/00-photo.png")).isEmpty,"missing EXIF stays unavailable rather than fabricated")
        var widthCases = 0
        for width:CGFloat in [248,264,304] { for mode in WorkspaceMode.allCases {
            let layout = WorkspaceLayout.resolve(size:CGSize(width:1440,height:900),mode:mode,inspectorWidth:width)
            precondition(layout.inspector.width == width && layout.safeCanvas.width >= 560); widthCases += 1
        } }
        check(widthCases == 6,"all three compact widths retain a valid A/B editing viewport")
        // Worst bright/dark photo behind the actual 84% neutral panel tint.
        func luminance(_ v:Double) -> Double { v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
        let dark = (luminance(0.79)+0.05)/(luminance(0.08*0.84+0.16)+0.05)
        let light = (luminance(0.84)+0.05)/(luminance(0.23)+0.05)
        check(min(dark,light) >= 4.5,"secondary numbers meet 4.5:1 on worst-case neutral matte composites")
        let result:[String:Any] = ["status":"passed","checks":(r2["checks"] as! Int)+checks,"r3Checks":checks,"r2Checks":r2["checks"]!,"layoutCases":(r2["layoutCases"] as! Int)+widthCases,"descriptors":all.count,"groups":ParameterGroupSchema.titles.count,"worstCaseContrast":["dark":dark,"light":light]]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:url)
        print("PASS: R3 workspace suite \(checks) new checks")
    }
}
