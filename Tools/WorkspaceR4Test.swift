import AppKit
import CoreImage
import ImageIO

@main struct WorkspaceR4Test {
    @MainActor static func main() async throws {
        try await WorkspaceR3Test.main()
        let reportURL = URL(fileURLWithPath:CommandLine.arguments[1]), out = reportURL.deletingLastPathComponent()
        let previous = try JSONSerialization.jsonObject(with:Data(contentsOf:reportURL)) as! [String:Any]
        var checks = 0
        func check(_ value:@autoclosure () -> Bool,_ name:String) {
            guard value() else { FileHandle.standardError.write(Data("FAIL R4: \(name)\n".utf8)); exit(1) }
            checks += 1; print("PASS R4: \(name)"); fflush(stdout)
        }
        func wait(_ condition:@escaping @MainActor () -> Bool) async throws {
            for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
            throw NSError(domain:"R4",code:1,userInfo:[NSLocalizedDescriptionKey:"async work timeout"])
        }
        let s = AppState(), session = WorkspaceSessionState(persist:false)
        let model = WorkspaceWindowModel(state:s,session:session)
        s.openFolder(out.appendingPathComponent("photo-fixtures")); try await wait { s.preview != nil && !s.previewing }
        s.commit(EditParams())
        var p = s.params; p.rotation = 90; p.flipped = true; p.straighten = 3; p.cropX = 0.17; p.cropY = 0.13; p.cropW = 0.65; p.cropH = 0.7; p.exposure = 1.2
        s.commit(p); try await wait { !s.previewing }
        session.viewport.mode = .manual; session.viewport.editedImageCenter = CGPoint(x:0.3,y:0.7)
        let original = s.params, history = s.history.stack, writes = s.workMetrics.snapshot["sidecarWrite"]!, center = session.viewport.editedImageCenter
        s.toggleCropMode(); s.set(\.cropW,0.5); s.endEdit(); s.set(\.rotation,180); s.endEdit()
        check(s.cropSession != nil && s.history.stack == history && s.workMetrics.snapshot["sidecarWrite"] == writes,"crop previews never write history or sidecars")
        s.cancelCrop(); check(s.params == original && s.history.stack == history && session.viewport.editedImageCenter == center,"crop cancel restores exact entering parameters and viewport")
        check(s.workMetrics.snapshot["sidecarWrite"] == writes,"crop cancel leaves no sidecar residue")
        s.toggleCropMode(); s.set(\.cropW,0.5); s.endEdit(); s.set(\.cropH,0.6); s.endEdit(); s.finishCrop(); s.finishCrop()
        check(s.history.stack.count == history.count+1 && s.workMetrics.snapshot["sidecarWrite"] == writes+1,"crop confirm commits exactly once after multiple operations")
        s.undo(); check(s.params == original,"one undo restores complete pre-crop state")
        s.toggleCropMode(); s.set(\.cropW,0.4); s.select(1); try await wait { !s.previewing }
        check(!s.cropMode && s.cropSession == nil,"switching photos cancels an open crop transaction")
        s.select(0); try await wait { !s.previewing }; check(s.params == original,"switching away from crop never saves its draft")
        s.splitComparison = true; try await wait { !s.previewing && s.geometryBeforeFrame != nil }
        let edited = s.previewFrame!, before = s.geometryBeforeFrame!
        check(before.key.purpose == .beforeGeometry && before.key.revision == edited.key.revision && before.key.photoID == edited.key.photoID,"split before and edited publish atomically at one photo and revision")
        check(before.bitmapSize == edited.bitmapSize && before.renderExtent == edited.renderExtent,"split halves have identical actual raster dimensions and geometry")
        s.showBefore = true; try await wait { s.beforeFrame != nil }
        check(!s.splitComparison && s.beforeFrame!.editedExtent == s.source!.extent,"original command retains the unedited source domain")
        s.splitComparison = true; s.select(2); s.select(3); try await wait { !s.previewing && s.geometryBeforeFrame?.key.photoID == s.current?.id }
        check(s.geometryBeforeFrame?.key.photoID == s.previewFrame?.key.photoID,"old split requests cannot replace a newly selected photo")
        s.splitComparison = false
        let extent = CGRect(x:37,y:-22,width:713,height:419), viewport = CGRect(x:50,y:70,width:730,height:480)
        for backing:CGFloat in [1,2] {
            let rect = CGRect(x:80,y:90,width:713/backing,height:419/backing)
            let t = DisplayTransform(outputExtent:extent,bitmapSize:extent.size,imageRect:rect,backingScale:backing)
            check(abs(t.screenPixelsPerEditedPixel-1)<1e-10,"pixel100 maps exactly one screen pixel at backing \(backing)")
            let anchor = CGPoint(x:rect.minX+rect.width*0.31,y:rect.minY+rect.height*0.67)
            let n = t.normalizedPoint(anchor)!
            var v = CanvasViewport(); v.zoom(factor:1.73,anchor:anchor,transform:t,viewport:viewport,backingScale:backing)
            let w = extent.width*v.screenPixelsPerEditedPixel/backing, h = extent.height*v.screenPixelsPerEditedPixel/backing
            let after = DisplayTransform(outputExtent:extent,bitmapSize:extent.size,imageRect:CGRect(x:viewport.midX-v.editedImageCenter.x*w,y:viewport.midY-(1-v.editedImageCenter.y)*h,width:w,height:h),backingScale:backing)
            let n2 = after.normalizedPoint(anchor)!
            check(hypot(n.x-n2.x,n.y-n2.y)<1e-10,"pointer zoom preserves the edited pixel anchor at backing \(backing)")
        }
        // Non-square, offset rendered markers with the exact same derived quad at two resolutions.
        let source = CIImage(color:CIColor(red:0.2,green:0.3,blue:0.4)).cropped(to:extent)
        let marker = CIImage(color:.red).cropped(to:CGRect(x:190,y:115,width:24,height:24)).composited(over:source)
        var geo = EditParams(); geo.perspectiveAuto = true; geo.rotation = 90; geo.flipped = true
        let resolved = Engine.ResolvedPerspective(normalized:(CGPoint(x:0.08,y:0.92),CGPoint(x:0.94,y:0.95),CGPoint(x:0.90,y:0.04),CGPoint(x:0.03,y:0.08)))
        let full = Engine.geometry(marker,geo,resolvedAuto:resolved)
        let proxy = Engine.geometry(marker.transformed(by:CGAffineTransform(scaleX:0.5,y:0.5)),geo,resolvedAuto:resolved)
        check(abs(full.extent.width-proxy.extent.width*2)<=2 && abs(full.extent.height-proxy.extent.height*2)<=2,"one normalized auto quad differs only by at most two raster-rounding pixels across 2x resolution")
        func markerCentroid(_ image:CIImage) -> CGPoint {
            let e = image.extent.integral, w = Int(e.width), h = Int(e.height)
            var bytes = [UInt8](repeating:0,count:w*h*4)
            Engine.ctx.render(image,toBitmap:&bytes,rowBytes:w*4,bounds:e,format:.RGBA8,colorSpace:Engine.srgb)
            var x = 0.0,y = 0.0,n = 0.0
            for j in 0..<h { for i in 0..<w { let k = (j*w+i)*4; if bytes[k]>200 && bytes[k+1]<40 { x+=Double(i);y+=Double(j);n+=1 } } }
            return CGPoint(x:x/max(n,1)/Double(w),y:y/max(n,1)/Double(h))
        }
        let f = markerCentroid(full), r = markerCentroid(proxy)
        check(hypot(f.x-r.x,f.y-r.y)<0.01,"rendered marker correspondence survives perspective, rotation, flip and nonzero origin within raster tolerance")
        check(Engine.ctx.createCGImage(full,from:full.extent) != nil,"perspective marker graph actually rasterizes")
        var auto = EditParams(); auto.perspectiveAuto = true
        let first = Engine.resolvedPerspective(marker,auto), second = Engine.resolvedPerspective(marker,auto)
        check(first != nil && second != nil,"even no-detection is a resolved session result, reused across preview and WB")
        let exifURL = out.appendingPathComponent("oriented-marker.jpg")
        let exifBitmap = Engine.ctx.createCGImage(marker,from:extent)!
        let exifDestination = CGImageDestinationCreateWithURL(exifURL as CFURL,"public.jpeg" as CFString,1,nil)!
        CGImageDestinationAddImage(exifDestination,exifBitmap,[kCGImagePropertyOrientation:6] as CFDictionary)
        check(CGImageDestinationFinalize(exifDestination),"EXIF marker fixture is written by ImageIO")
        let oriented = Engine.decode(exifURL)!
        check(oriented.extent.width == extent.height && oriented.extent.height == extent.width,"EXIF orientation is decoded before the editing transform")
        let wb1 = Engine.sampledWhiteBalance(marker,params:auto,point:CGPoint(x:0.8,y:0.8))
        let wb2 = Engine.sampledWhiteBalance(marker,params:auto,point:CGPoint(x:0.8,y:0.8))
        check(wb1 != nil && wb1 == wb2,"WB repeatedly samples the same derived automatic geometry before toning")
        s.createMask(.linear); let hc = s.history.stack.count, wc = s.workMetrics.snapshot["sidecarWrite"]!
        var draft = Mask(); draft.kind = .linear; s.updateMaskDraft(draft); s.cancelMaskDrawing()
        check(s.params.masks.isEmpty && s.history.stack.count == hc && s.workMetrics.snapshot["sidecarWrite"] == wc,"cancelled gradient draft creates no empty mask, history or sidecar")
        s.activateBrush(); let id = s.selectedMask!
        check(s.params.masks.count == 1 && s.params.masks[0].kind == .brush && s.maskTool == .paint,"brush without a target creates and selects a valid brush mask")
        s.renameMask(id,name:"  天空细节  "); check(s.params.masks[0].name == "天空细节","mask rename trims and persists the real mask")
        let start = s.params, h = s.history.stack.count
        let token = s.parameterEdits.begin(); var brush = s.params.masks[0]
        brush.strokes = [Stroke(pts:[[0.2,0.7],[0.4,0.7]],radius:0.04,feather:0.5,erasing:false)]
        s.updateMaskLive(brush); s.parameterEdits.invalidate()
        check(s.params == start && s.history.stack.count == h && !s.parameterEdits.valid(token),"cancelling an actual stroke restores the complete mask without history")
        let done = s.parameterEdits.begin(); s.updateMaskLive(brush); _ = s.parameterEdits.complete(done); s.endEdit(); s.endEdit()
        check(s.history.stack.count == h+1 && s.params.masks[0].strokes.count == 1,"one completed stroke produces one undo entry")
        s.undo(); check(s.params == start,"stroke undo restores the prior mask")
        check(model.enabled(.masks) && model.enabled(.brush) && !model.enabled(.cancelJob),"command registry exposes real idle tool and cancel states")
        s.selectedPhotos = []; check(!model.enabled(.sync),"sync command disabled without targets")
        s.selectedPhotos = [s.items[1].id]; check(model.enabled(.sync),"sync command enabled for real targets")
        model.perform(.copy); check(s.copiedParams == s.params,"copy command shares the actual adjustment model")
        var sync = s.params; sync.exposure = 0.44
        await s.synchronize(sync,to:[s.items[1].url],groups:[.tone])
        check(!s.syncRunning && s.syncProgress == 1 && SidecarStore.load(for:s.items[1].url)?.params.exposure == 0.44,"sync progress reaches completion only after the target sidecar is written")
        s.createSnapshot(name:"R4验收"); s.setRating(4); let saved = s.params, name = s.current!.url
        s.select(4); try await wait { !s.previewing }; s.select(s.items.firstIndex(where:{$0.url == name})!); try await wait { !s.previewing }
        check(s.params == saved && s.current?.rating == 4 && s.snapshots.last?.name == "R4验收","switch and reopen restore exact parameters, rating and snapshot")
        let exported = out.appendingPathComponent("r4-batch"); try FileManager.default.createDirectory(at:exported,withIntermediateDirectories:true)
        s.exportSettings.format = "tiff"; s.exportSettings.tiffBitDepth = 16
        s.items[s.currentIndex].picked = true; _ = s.saveCurrent()
        await s.batchExport(to:exported,onlyPicked:true)
        check(!s.batchRunning && s.batchProgress == 1 && s.jobFailures.isEmpty,"real batch export completes, clears busy state and reports no failures")
        let file = exported.appendingPathComponent(name.deletingPathExtension().lastPathComponent+".tiff")
        let decoded = CGImageSourceCreateWithURL(file as CFURL,nil)!, image = CGImageSourceCreateImageAtIndex(decoded,0,nil)!
        check(image.bitsPerComponent == 16,"R4 workflow produces actual 16-bit TIFF")
        let bad = s.items[4].url, badPath = SidecarStore.url(for:bad), damaged = Data("{broken".utf8)
        try damaged.write(to:badPath)
        s.items = s.items.map { var i = $0;i.picked = i.url == bad;return i }
        await s.batchExport(to:exported,onlyPicked:true)
        check(!s.jobFailures.isEmpty && (try? Data(contentsOf:badPath)) == damaged,"batch fails safely on damaged sidecars and preserves their bytes")
        s.workflowError = nil
        s.startBatchExport(to:exported,onlyPicked:false)
        try await wait { s.batchRunning }; s.cancelJobs(); try await wait { !s.jobRunning }
        check(s.status.contains("取消") && s.batchProgress<1 && s.jobCancellation == nil,"cancelled batch cannot report completion and releases the command state")
        check(model.enabled(.batch) && model.enabled(.export),"output commands re-enable after cancellation")
        s.toggleCropMode(); s.set(\.cropW,0.3); s.finishWindowWork()
        check(!s.cropMode && s.params == saved && s.pendingPhotoEditID == nil && !s.temporaryPan,"window close cancels transient crop and releases editing context")
        var result = previous;result["r4Checks"] = checks;result["checks"] = (previous["checks"] as! Int)+checks
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL)
        print("R4 complete: \(checks) checks")
    }
}
