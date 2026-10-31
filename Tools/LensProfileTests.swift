import Foundation
import CoreImage
import AppKit

enum L10n { static func tr(_ s:String)->String{s} }
@main struct LensProfileTests {
    @MainActor static func main() throws {
        var checks=0
        func check(_ condition:Bool,_ label:String) { guard condition else { fatalError("FAIL: "+label) }; checks+=1; print("PASS: "+label) }
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), dbURL=URL(fileURLWithPath:CommandLine.arguments[2]); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let sample="""
        <lensdatabase version="2"><lens><maker>Test</maker><model>EF Test</model><mount>Canon EF</mount><cropfactor>1</cropfactor><calibration>
        <distortion model="poly3" focal="20" k1="-0.1"/><distortion model="poly3" focal="40" k1="-0.02"/>
        <tca model="linear" focal="20" kr="1.001" kb="0.999"/><tca model="linear" focal="40" kr="1.002" kb="0.998"/>
        <vignetting model="pa" focal="20" aperture="4" distance="10" k1="-0.3" k2="0" k3="0"/>
        <vignetting model="pa" focal="40" aperture="4" distance="10" k1="-0.3" k2="0" k3="0"/>
        </calibration></lens></lensdatabase>
        """
        let data=Data(sample.utf8), db=try LensXMLReader.read(data), p=db.profiles[0]
        check(db.profiles.count==1,"valid XML supported")
        let c=p.resolve(focal:30,aperture:4,distance:10,cameraCrop:1)!
        check(abs(c.distortion!.coefficients[1]+0.06)<1e-9,"focal coefficients interpolate")
        check(abs(c.tca!.coefficients[2]-1.0015)<1e-9,"TCA focal interpolation")
        check(!c.correctVignetting && c.vignetting != nil,"nearest vignetting sample available but initially off")
        check(p.resolve(focal:60,aperture:4,distance:10,cameraCrop:1) == nil,"out-of-range distortion never extrapolates")
        check(p.resolve(focal:30,aperture:4,distance:10,cameraCrop:0.7)==nil,"larger sensor rejected")
        check(p.resolve(focal:30,aperture:0,distance:10,cameraCrop:1)?.vignetting==nil,"missing aperture disables vignetting")
        let decoded=try JSONDecoder().decode(LensCorrection.self,from:JSONEncoder().encode(c)); check(decoded==c,"portable calibration snapshot round-trips")
        func rejects(_ text:String)->Bool{ (try? LensXMLReader.read(Data(text.utf8))) == nil }
        check(rejects("<lensdatabase>"),"malformed XML rejected")
        check(rejects(sample.replacingOccurrences(of:"-0.1",with:"NaN")),"nonfinite coefficients rejected")
        check(rejects(sample.replacingOccurrences(of:"<mount>",with:"<type>fisheye</type><mount>")),"fisheye is not treated as rectilinear")
        check(rejects(sample.replacingOccurrences(of:"poly3",with:"acm").replacingOccurrences(of:"linear",with:"acm").replacingOccurrences(of:"pa\"",with:"acm\"")),"unsupported-only XML rejected")
        check(rejects("<!DOCTYPE lensdatabase [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>"+sample),"external entity payload rejected")
        check(rejects("<!DOCTYPE lensdatabase SYSTEM 'https://example.com/evil.dtd'>"+sample),"external DTD rejected")
        check((try? LensXMLReader.read(Data(repeating:65,count:8*1024*1024+1))) == nil,"oversized import rejected")
        let real=try LensXMLReader.read(Data(contentsOf:dbURL)); check(real.profiles.count==5,"compact five-profile bundle parses")
        check(!real.profiles.contains{$0.name.localizedCaseInsensitiveContains("fisheye")},"unmarked fisheye excluded by name")
        check(real.profiles.contains{$0.name.contains("EF 24-105mm f/4L IS USM")},"older EF 24-105 profile present")
        let file=root.appendingPathComponent("input.xml"); try data.write(to:file)
        let store=LensProfileStore(directory:root.appendingPathComponent("library"),bundledURL:dbURL)
        check(try store.importFile(file)==1,"valid import persists in isolated library")
        check(try Data(contentsOf:file)==data,"import source untouched")
        check(store.matches("EF Test").count==1,"imported lens can be matched")
        let again=LensProfileStore(directory:store.directory,bundledURL:dbURL); check(again.matches("EF Test").count==1,"import survives restart")
        let sigma=real.profiles.first{$0.name.contains("16-300")}!
        check(store.matches("SIGMA 16-300mm F3.5-6.7 DC OS | Contemporary 025").count==1,"Sigma EXIF brand alias matches")
        for focal in [16.0,18.9,24,35,50,100,200,300] {
            let resolved=sigma.resolve(focal:focal,aperture:6.7,distance:10,cameraCrop:1.534)
            check(resolved?.distortion != nil && resolved?.tca != nil && resolved?.vignetting == nil,"Sigma calibration at \(focal) mm with honest capability flags")
        }
        let libraryFiles=try FileManager.default.contentsOfDirectory(at:store.directory,includingPropertiesForKeys:nil)
        for f in libraryFiles { try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1)],ofItemAtPath:f.path) }
        let revised=Data(sample.replacingOccurrences(of:"k1=\"-0.1\"",with:"k1=\"-0.08\"").utf8)
        let revisionFile=root.appendingPathComponent("revision.xml"); try revised.write(to:revisionFile)
        _ = try store.importFile(revisionFile)
        let updated=LensProfileStore(directory:store.directory,bundledURL:dbURL).matches("EF Test")[0]
        check(abs(updated.distortion[0].coefficients[1]+0.08)<1e-9,"newer import overrides earlier calibration after restart")
        check(LensProfileEngine.kernel != nil,"Core Image correction kernel compiles")
        let center=LensProfileEngine.mapping(.zero,aspect:1.5,correction:c)
        check(center == .zero,"optical center remains fixed")
        var noCrop=c; noCrop.autoCrop=false
        check(LensProfileEngine.cropScale(aspect:1.5,correction:noCrop)==1,"crop-off preserves scale")
        var positive=c; positive.distortion!.coefficients=[0,0.1,0,0.9]
        let zoom=LensProfileEngine.cropScale(aspect:1.5,correction:positive)
        check(zoom>1 && zoom<4,"positive distortion auto-crops empty boundary")
        let a=1.5,hx=a/sqrt(1+a*a),hy=1/sqrt(1+a*a)
        let edge=LensProfileEngine.mapping(CGPoint(x:hx,y:hy),aspect:a,correction:positive,scale:zoom,channel:0)
        check(abs(edge.x)<=hx && abs(edge.y)<=hy,"auto-crop keeps corner sampling inside source")
        let color=CIImage(color:CIColor(red:0.2,green:0.2,blue:0.2)).cropped(to:CGRect(x:0,y:0,width:120,height:80))
        var vig=c; vig.correctDistortion=false; vig.correctTCA=false; vig.correctVignetting=true; vig.autoCrop=false
        let output=LensProfileEngine.apply(color,vig),ctx=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.linearSRGB)!])
        func pixel(_ image:CIImage,_ x:Int,_ y:Int)->Float { var f=[Float](repeating:0,count:4); ctx.render(image,toBitmap:&f,rowBytes:16,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.linearSRGB)!); return f[0] }
        check(pixel(output,2,2)>pixel(output,60,40)*1.15,"vignetting genuinely brightens corners")
        var disabled=vig; disabled.enabled=false
        check(abs(pixel(LensProfileEngine.apply(color,disabled),2,2)-pixel(color,2,2))<0.00001,"disabled correction preserves pixels")
        check(output.extent==color.extent,"output dimensions preserved")
        let proxy=color.transformed(by:CGAffineTransform(scaleX:0.5,y:0.5))
        check(abs(pixel(LensProfileEngine.apply(proxy,vig),1,1)-pixel(output,2,2))<0.003,"proxy and full-size corrections agree")
        var wrong=c; wrong.tca=wrong.distortion; check(!wrong.valid,"mismatched snapshot channel structure rejected")
        var gradient=[Float]()
        for _ in 0..<80 { for x in 0..<120 { let v=Float(x)/120; gradient += [v,v,v,1] } }
        let linear=CGColorSpace(name:CGColorSpace.linearSRGB)!
        let gradientData=gradient.withUnsafeBytes{Data($0)}
        let ramp=CIImage(bitmapData:gradientData,bytesPerRow:120*16,size:CGSize(width:120,height:80),format:.RGBAf,colorSpace:linear)
        var warp=c; warp.autoCrop=false; warp.correctTCA=false
        let q=LensProfileEngine.mapping(CGPoint(x:30/hypot(60.0,40.0),y:0),aspect:1.5,correction:warp)
        let expected=(60+q.x*hypot(60.0,40.0))/120
        check(abs(Double(pixel(LensProfileEngine.apply(ramp,warp),90,40))-expected)<0.015,"GPU distortion follows reference coordinate mapping")
        var chromatic=c; chromatic.distortion=nil; chromatic.autoCrop=false
        chromatic.tca!.coefficients=[0,0,1.05,0,0,0.95]
        let rgb=LensProfileEngine.apply(ramp,chromatic); var px=[Float](repeating:0,count:4)
        ctx.render(rgb,toBitmap:&px,rowBytes:16,bounds:CGRect(x:90,y:40,width:1,height:1),format:.RGBAf,colorSpace:linear)
        check(px[0]>px[1] && px[1]>px[2],"GPU TCA samples each color channel independently")
        var folded=c; folded.distortion!.coefficients=[0,-10,0,1]; check(!folded.valid,"folding radial polynomial rejected")
        if let cg=ctx.createCGImage(output,from:output.extent) { let image=NSBitmapImageRep(cgImage:cg); try image.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("vignetting-proof.png")) }
        let result:[String:Any]=["status":"passed","checks":checks,"bundledSupportedLenses":real.profiles.count]
        try JSONSerialization.data(withJSONObject:result,options:.prettyPrinted).write(to:root.appendingPathComponent("lens-tests.json")); print(result)
    }
}
